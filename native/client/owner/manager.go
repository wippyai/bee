// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"

	"github.com/wippyai/runtime/api/dispatcher"
	apierror "github.com/wippyai/runtime/api/error"
	"github.com/wippyai/runtime/api/relay"
	secapi "github.com/wippyai/runtime/api/security"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/runtime/security"
)

// Manager owns active and pending local display attachments independently
// of presentations or client processes.
type Manager struct {
	mu       sync.Mutex
	acceptor Acceptor
	active   map[*Attachment]string
	owners   map[string]int
	pending  int
	closed   atomic.Bool
	ctx      context.Context
	cancel   context.CancelFunc
	wait     sync.WaitGroup
}

// New creates a new Manager backed by the provided host-injected Acceptor.
func New(acceptor Acceptor) *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		acceptor: acceptor,
		active:   make(map[*Attachment]string),
		owners:   make(map[string]int),
		ctx:      ctx,
		cancel:   cancel,
	}
}

// NewManager is an alias for New.
func NewManager(acceptor Acceptor) *Manager {
	return New(acceptor)
}

func (m *Manager) isClosed() bool {
	return m.closed.Load()
}

func (m *Manager) removeAttachment(att *Attachment) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if owner, ok := m.active[att]; ok {
		delete(m.active, att)
		m.owners[owner]--
		if m.owners[owner] <= 0 {
			delete(m.owners, owner)
		}
	}
}

// Handle processes the accept dispatcher command (0xbee1) yielded from Lua.
func (m *Manager) Handle(ctx context.Context, command dispatcher.Command, tag uint64, receiver dispatcher.ResultReceiver) error {
	req, ok := command.(*acceptCommandPayload)
	if !ok {
		return fmt.Errorf("unexpected localdisplay command")
	}

	// Security authorization check: caller must have exact action and resource.
	secCtx := ctx
	if _, hasActor := secapi.GetActor(req.frameContext); hasActor {
		secCtx = req.frameContext
	}
	if !security.IsAllowed(secCtx, SecurityAction, SecurityResource, nil) ||
		(secCtx != ctx && !security.IsAllowed(ctx, SecurityAction, SecurityResource, nil)) {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.PermissionDenied, "local display accept is not permitted").WithRetryable(apierror.False))
		return nil
	}

	ttyService := ttyapi.GetService(req.frameContext)
	if ttyService == nil {
		ttyService = ttyapi.GetService(ctx)
	}
	if ttyService == nil {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Unavailable, "tty service unavailable"))
		return nil
	}

	node := relay.GetNode(ctx)
	if node == nil {
		node = relay.GetNode(req.frameContext)
	}

	m.mu.Lock()
	if m.closed.Load() {
		m.mu.Unlock()
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Unavailable, "local display manager stopped"))
		return nil
	}

	ownerStr := req.owner.String()
	if m.pending+len(m.active) >= MaxConnections || m.owners[ownerStr] >= MaxOwnerConnections {
		m.mu.Unlock()
		receiver.CompleteYield(tag, nil, apierror.New(apierror.RateLimited, "local display connection limit reached"))
		return nil
	}
	m.pending++
	m.wait.Add(1) // Count pending accepts before publishing the goroutine.
	m.owners[ownerStr]++
	m.mu.Unlock()

	go m.runAccept(req, tag, receiver, ttyService, node)
	return nil
}

func (m *Manager) runAccept(
	req *acceptCommandPayload,
	tag uint64,
	receiver dispatcher.ResultReceiver,
	ttyService ttyapi.Service,
	node relay.Node,
) {
	defer m.wait.Done()
	ownerStr := req.owner.String()
	slotClaimed := true
	releasePending := func() {
		if slotClaimed {
			m.mu.Lock()
			m.pending--
			m.owners[ownerStr]--
			if m.owners[ownerStr] <= 0 {
				delete(m.owners, ownerStr)
			}
			m.mu.Unlock()
			slotClaimed = false
		}
	}
	defer releasePending()

	if m.acceptor == nil {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Unavailable, "acceptor is nil"))
		return
	}

	// Link manager shutdown context and caller yield context
	acceptCtx, cancelAccept := context.WithCancel(req.context)
	defer cancelAccept()

	stopWatch := make(chan struct{})
	watchDone := make(chan struct{})
	go func() {
		defer close(watchDone)
		select {
		case <-m.ctx.Done():
			cancelAccept()
		case <-stopWatch:
		}
	}()
	defer func() { close(stopWatch); <-watchDone }()

	// 1. Accept from host acceptor off the scheduler thread
	conn, err := m.acceptor.Accept(acceptCtx)
	if err != nil {
		receiver.CompleteYield(tag, nil, err)
		return
	}
	if err := acceptCtx.Err(); err != nil {
		if conn != nil {
			_ = conn.Close()
		}
		receiver.CompleteYield(tag, nil, err)
		return
	}
	if conn == nil {
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Internal, "acceptor returned nil connection"))
		return
	}

	// 2. Create viewport using the ACTUAL caller frame context, never a fabricated PID
	viewport, err := ttyService.Create(req.frameContext, req.width, req.height)
	if err != nil {
		_ = conn.Close()
		receiver.CompleteYield(tag, nil, err)
		return
	}

	// 3. Re-check context before publishing
	if err := acceptCtx.Err(); err != nil {
		_ = conn.Close()
		_ = viewport.Close()
		receiver.CompleteYield(tag, nil, err)
		return
	}

	// 4. Create attachment and transition from pending to active
	m.mu.Lock()
	if m.closed.Load() {
		m.mu.Unlock()
		_ = conn.Close()
		_ = viewport.Close()
		receiver.CompleteYield(tag, nil, apierror.New(apierror.Unavailable, "local display manager stopped"))
		return
	}

	m.pending--
	slotClaimed = false // Transferred to active
	attachment := newAttachment(m, conn, viewport, req, node)
	m.active[attachment] = ownerStr
	m.wait.Add(1) // For Serve goroutine
	m.mu.Unlock()

	// Start independent cancellation watcher to prevent any leak if CompleteYield is dropped
	attachment.startCancellationWatcher(req.context)

	// Start Serve goroutine
	go attachment.runServe()

	// 5. Complete yield to scheduler
	receiver.CompleteYield(tag, attachment, nil)
}

// Stop shuts down the manager, closes all active attachments, and joins
// all background Serve goroutines. Detached viewports never terminate producers.
func (m *Manager) Stop(ctx context.Context) error {
	m.closed.Store(true)
	m.cancel()

	m.mu.Lock()
	attachments := make([]*Attachment, 0, len(m.active))
	for att := range m.active {
		attachments = append(attachments, att)
	}
	m.mu.Unlock()

	for _, att := range attachments {
		att.Close()
	}

	done := make(chan struct{})
	go func() {
		m.wait.Wait()
		close(done)
	}()

	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return errors.Join(fmt.Errorf("waiting for display serve goroutines to close"), ctx.Err())
	}
}

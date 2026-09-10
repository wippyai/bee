// SPDX-License-Identifier: MIT

// Package computer owns one explicitly selected OS seat. Experimental native
// boundary: not registered as a public Lua module or Hive operation yet.
package computer

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"sync"
	"time"

	"github.com/wippyai/bee/native/computer/driver"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	security "github.com/wippyai/runtime/api/security"
)

var (
	ErrDenied    = errors.New("computer access denied")
	ErrBusy      = errors.New("computer seat busy")
	ErrRetired   = errors.New("computer endpoint retired")
	ErrUncertain = errors.New("computer transport failed; outcome uncertain; do not replay")
)

// Owner is constructed once per seat by trusted host composition. Executable,
// node and resource must never come from an application request or discovery.
// The same executable must dispatch --bee-computer-driver to driver.Run().
type Owner struct {
	mu                         sync.Mutex
	executable, node, resource string
	active                     *Lease
	stopped                    bool
	recovery                   *recoveryState
}

// Lease is an opaque process-owned handle. Endpoint/Session are descriptions,
// never bearer authorization. Closing or losing a process retires this handle.
type Lease struct {
	retired           bool // protected by owner.mu; retained until observed child exit
	owner             *Owner
	actor, pid        string
	endpoint, session string
	expires           time.Time
	cmd               *exec.Cmd
	input             io.WriteCloser
	reader            *bufio.Reader
	sequence          int
	exited            chan struct{}
	cancel            context.CancelFunc
}

func New(executable, node, resource, recoveryDirectory string) (*Owner, error) {
	if executable == "" || resource == "" || len(resource) > 256 || len(node) > 256 {
		return nil, ErrDenied
	}
	state, err := newRecovery(recoveryDirectory, node, resource)
	if err != nil {
		return nil, err
	}
	return &Owner{executable: executable, node: node, resource: resource, recovery: state}, nil
}

// identity reads only the real native caller frame and explicit runtime scope.
// Missing security always denies, even when runtime permissive mode is enabled.
func (o *Owner) identity(ctx context.Context, operation string) (string, string, error) {
	p, ok := runtimeapi.GetFramePID(ctx)
	actor, hasActor := security.GetActor(ctx)
	if ctx.Err() != nil || !ok || p.Node != o.node || p.Host == "" || p.UniqID == "" || !hasActor || actor.ID == "" ||
		!security.IsAllowed(ctx, "bee.computer."+operation, o.resource, nil) {
		return "", "", ErrDenied
	}
	return actor.ID, p.String(), nil
}

// Open must receive the authenticated caller's process-lifetime context. Its
// cancellation kills the child even without another request. One lease per seat.
func (o *Owner) Open(ctx context.Context) (*Lease, error) {
	actor, p, err := o.identity(ctx, "control")
	if err != nil {
		return nil, err
	}
	if !o.mu.TryLock() {
		return nil, ErrBusy
	}
	defer o.mu.Unlock()
	if o.stopped {
		return nil, ErrRetired
	}
	if o.active != nil {
		select {
		case <-o.active.exited:
			o.retireLocked()
			o.active = nil
		default:
			return nil, ErrBusy
		}
	}
	if err := o.recovery.available(ctx); err != nil {
		return nil, errors.Join(ErrRecovery, err)
	}
	childCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	cmd := exec.CommandContext(childCtx, o.executable, "--bee-computer-driver")
	// Arguments are fixed by trusted composition. No network listener is opened.
	cmd.WaitDelay = time.Second
	in, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		cancel()
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		in.Close()
		out.Close()
		cancel()
		return nil, err
	}
	l := &Lease{owner: o, actor: actor, pid: p, cmd: cmd, input: in, reader: bufio.NewReaderSize(out, 64*1024), exited: make(chan struct{}), cancel: cancel, expires: time.Now().Add(30 * time.Second)}
	o.active = l
	go func() { _ = cmd.Wait(); close(l.exited) }()
	reply, _, err := l.rpc(ctx, driver.Request{Op: "hello"})
	if err != nil || len(reply.Endpoint) != 32 || reply.Session == "" || len(reply.Session) > 128 {
		o.retireLocked()
		return nil, ErrRetired
	}
	l.endpoint, l.session = reply.Endpoint, reply.Session
	return l, nil
}

// Do performs at most one request; concurrent callers get Busy, not a queue.
// Request IDs and endpoint binding are owner-selected, not caller-selected.
func (l *Lease) Do(ctx context.Context, request driver.Request) (driver.Reply, []byte, error) {
	o := l.owner
	if !validRequest(request) {
		return driver.Reply{}, nil, ErrDenied
	}
	actor, p, err := o.identity(ctx, request.Op)
	if err != nil || actor != l.actor || p != l.pid {
		return driver.Reply{}, nil, ErrDenied
	}
	if !o.mu.TryLock() {
		return driver.Reply{}, nil, ErrBusy
	}
	defer o.mu.Unlock()
	if o.active != l || l.retired || time.Now().After(l.expires) {
		return driver.Reply{}, nil, ErrRetired
	}
	select {
	case <-l.exited:
		o.retireLocked()
		return driver.Reply{}, nil, ErrRetired
	default:
	}
	var pending string
	if request.Op == "act" {
		pending, err = o.recovery.begin(ctx, l.session)
		if err != nil {
			return driver.Reply{}, nil, errors.Join(ErrRecovery, err)
		}
	}
	reply, data, err := l.rpc(ctx, request)
	if err != nil {
		o.retireLocked()
		return driver.Reply{}, nil, ErrUncertain
	}
	if reply.Endpoint != l.endpoint || reply.Session != l.session {
		o.retireLocked()
		return driver.Reply{}, nil, ErrUncertain
	}
	if pending != "" {
		settled := reply.Error != "" && len(reply.Outcomes) == 0
		if reply.Error == "" && len(reply.Outcomes) == len(request.Actions) && len(request.Actions) > 0 {
			settled = true
			for _, outcome := range reply.Outcomes {
				if outcome != "injected" && outcome != "skipped" {
					settled = false
				}
			}
		}
		if !settled {
			o.retireLocked()
			return reply, nil, errors.Join(ErrUncertain, ErrRecovery)
		}
		if err := o.recovery.complete(ctx, pending); err != nil {
			o.retireLocked()
			return reply, nil, errors.Join(ErrRecovery, err)
		}
	}
	return reply, data, nil
}

func (l *Lease) rpc(ctx context.Context, q driver.Request) (driver.Reply, []byte, error) {
	l.sequence++
	q.ID = l.sequence
	q.Endpoint = l.endpoint
	raw, err := json.Marshal(q)
	if err != nil || len(raw) >= 64*1024 {
		return driver.Reply{}, nil, ErrDenied
	}
	// Bounded operation deadline. Cancellation terminates the endpoint; a timed-out
	// request is never sent again, regardless of whether native input took effect.
	operation, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	stop := context.AfterFunc(operation, func() { l.cancel() })
	defer stop()
	if _, err = l.input.Write(append(raw, '\n')); err != nil {
		return driver.Reply{}, nil, err
	}
	line, err := l.reader.ReadSlice('\n')
	if err != nil {
		return driver.Reply{}, nil, err
	}
	var reply driver.Reply
	if err = json.Unmarshal(line, &reply); err != nil {
		return reply, nil, err
	}
	if reply.ID != q.ID || reply.Bytes < 0 || reply.Bytes > 16*1024*1024 || len(reply.Outcomes) > 32 {
		return reply, nil, ErrRetired
	}
	data := make([]byte, reply.Bytes)
	_, err = io.ReadFull(l.reader, data)
	if operation.Err() != nil {
		return reply, nil, operation.Err()
	}
	return reply, data, err
}

func (o *Owner) retireLocked() {
	if o.active != nil {
		o.active.cancel()
		_ = o.active.input.Close()
		o.active.retired = true
	}
}

// Revoke is a host-only lifecycle operation; it is not exposed to applications.
// Completion joins child exit; failure never reports successful shutdown.
func (o *Owner) Revoke(ctx context.Context) error {
	o.mu.Lock()
	l := o.active
	o.retireLocked()
	o.mu.Unlock()
	if l == nil {
		return nil
	}
	select {
	case <-l.exited:
		if err := o.recovery.available(ctx); err != nil {
			return errors.Join(ErrRecovery, err)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (o *Owner) Stop(ctx context.Context) error {
	o.mu.Lock()
	o.stopped = true
	o.mu.Unlock()
	return o.Revoke(ctx)
}

// RecoverAfterLogon is explicitly permission-gated and never performs logoff.
// Host composition selects the same stable physical-seat directory. Ordinary
// control permission does not permit clearing unresolved input state.
func (o *Owner) RecoverAfterLogon(ctx context.Context) error {
	if _, _, err := o.identity(ctx, "recover"); err != nil {
		return err
	}
	if !o.mu.TryLock() {
		return ErrBusy
	}
	defer o.mu.Unlock()
	if o.active != nil {
		select {
		case <-o.active.exited:
		default:
			return ErrBusy
		}
	}
	return o.recovery.resolve(ctx, driver.VerifyNewLogon)
}

// Reject oversized values before JSON allocation or child IPC.
func validRequest(q driver.Request) bool {
	if q.Op != "observe" && q.Op != "act" {
		return false
	}
	if len(q.BasedOn) > 32 || len(q.Actions) > 32 {
		return false
	}
	for _, a := range q.Actions {
		if len(a.Kind) > 16 || len(a.Text) > 1024 || len(a.Key) > 32 {
			return false
		}
	}
	return true
}

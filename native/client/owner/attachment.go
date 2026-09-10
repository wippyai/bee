// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"

	"github.com/wippyai/bee/native/client/display"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/runtime/lua/engine"
)

// Attachment represents an active display bridge between an admitted connection
// and a process-owned native TTY viewport.
type Attachment struct {
	manager    *Manager
	conn       net.Conn
	viewport   ttyapi.Viewport
	grant      string
	owner      pid.PID
	epoch      uint64
	topic      string
	subID      uint64
	generation *atomic.Uint64
	node       relay.Node

	serveCtx    context.Context
	serveCancel context.CancelFunc

	closed       atomic.Bool
	closedBySelf atomic.Bool
	closeOnce    sync.Once
	emitOnce     sync.Once
	serveDone    chan struct{}
}

func newAttachment(
	manager *Manager,
	conn net.Conn,
	viewport ttyapi.Viewport,
	req *acceptCommandPayload,
	node relay.Node,
) *Attachment {
	serveCtx, serveCancel := context.WithCancel(context.Background())
	return &Attachment{
		manager:     manager,
		conn:        conn,
		viewport:    viewport,
		grant:       viewport.Grant(),
		owner:       req.owner,
		epoch:       req.epoch,
		topic:       req.topic,
		subID:       req.id,
		generation:  req.generation,
		node:        node,
		serveCtx:    serveCtx,
		serveCancel: serveCancel,
		serveDone:   make(chan struct{}),
	}
}

// Grant returns the native TTY viewport grant.
// This is returned to local Lua only and never sent across the physical wire.
func (a *Attachment) Grant() string {
	return a.grant
}

// Close detaches the consumer from the viewport and closes the connection.
// It returns true if this call transitioned the attachment to closed.
// Detached consumer never terminates the underlying producer process.
func (a *Attachment) Close() bool {
	if a.closed.Swap(true) {
		return false
	}
	a.closedBySelf.Store(true)
	a.serveCancel()
	if a.conn != nil {
		_ = a.conn.Close()
	}
	if a.viewport != nil {
		_ = a.viewport.Close()
	}
	a.emitClosed(nil)
	return true
}

func (a *Attachment) startCancellationWatcher(ctx context.Context) {
	if ctx == nil {
		return
	}
	a.manager.wait.Add(1)
	go func() {
		defer a.manager.wait.Done()
		select {
		case <-ctx.Done():
			a.Close()
		case <-a.serveDone:
		}
	}()
}

func (a *Attachment) runServe() {
	defer a.manager.wait.Done()
	defer close(a.serveDone)
	defer a.manager.removeAttachment(a)

	err := display.Serve(a.serveCtx, a.conn, a.viewport)

	if !a.closed.Swap(true) {
		if a.conn != nil {
			_ = a.conn.Close()
		}
		if a.viewport != nil {
			_ = a.viewport.Close()
		}
	}

	a.emitClosed(err)
}

func (a *Attachment) emitClosed(serveErr error) {
	a.emitOnce.Do(func() {
		errCode := mapServeError(serveErr, a.closedBySelf.Load(), a.manager.isClosed())
		event := Closed{
			Kind:      "closed",
			ErrorCode: errCode,
		}

		if a.node == nil {
			return
		}

		var gen uint64
		if a.generation != nil {
			gen = a.generation.Load()
		}

		frame := &engine.SubscriptionFrame{
			Epoch:    a.epoch,
			SubID:    a.subID,
			Gen:      gen,
			Payloads: payload.Payloads{payload.NewPayload(event, payload.Golang)},
		}
		msg := relay.NewPackage(pid.PID{}, a.owner, a.topic, engine.NewSubscriptionFramePayload(frame))
		for _, item := range msg.Messages {
			item.MaxItems = closedBuffer
			item.MaxBytes = 64 * 1024
			item.PayloadBytes = 128
		}
		_ = a.node.Send(msg)
	})
}

func mapServeError(err error, closedByLocal bool, managerStopped bool) string {
	if closedByLocal {
		return ErrorCodeClosed
	}
	if managerStopped {
		return ErrorCodeServiceStopped
	}
	if err == nil {
		return ErrorCodeOK
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return ErrorCodeCanceled
	}
	if errors.Is(err, display.ErrHandshakeMismatch) ||
		errors.Is(err, display.ErrOutOfSequence) ||
		errors.Is(err, display.ErrPacketTooLarge) ||
		errors.Is(err, display.ErrPacketTooSmall) ||
		errors.Is(err, display.ErrInvalidUTF8) ||
		errors.Is(err, display.ErrTrailingContent) ||
		errors.Is(err, display.ErrUnknownField) ||
		errors.Is(err, display.ErrDuplicateField) ||
		errors.Is(err, display.ErrNullField) ||
		errors.Is(err, display.ErrMissingField) ||
		errors.Is(err, display.ErrInvalidMessage) ||
		errors.Is(err, display.ErrInvalidEvent) ||
		errors.Is(err, display.ErrInvalidSnapshot) {
		return ErrorCodeProtocolError
	}
	if errors.Is(err, display.ErrClosed) || errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
		return ErrorCodeClosed
	}
	return ErrorCodeIOError
}

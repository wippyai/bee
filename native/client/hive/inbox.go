//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"errors"

	"github.com/wippyai/bee/native/client/mesh"
)

const clipboardTopic = "bee.clipboard.request"
const inboxCapacity = 8

var ErrInboxOverflow = errors.New("Hive client inbox overflow; pending operations are not replayed")

// inbox is the sole reader of the native actor. Routing does not authorize a
// message: each consumer must check the exact sender and its operation identity.
// Both queues are bounded; overflow retires the entire client instead of
// silently losing an operation. Clipboard messages never enter the reply queue.
type inbox struct {
	transport
	ctx       context.Context
	cancel    context.CancelCauseFunc
	replies   chan mesh.Message
	clipboard chan mesh.Message
	done      chan struct{}
}

func newInbox(ctx context.Context, actor transport) *inbox {
	lifetime, cancel := context.WithCancelCause(ctx)
	i := &inbox{transport: actor, ctx: lifetime, cancel: cancel,
		replies: make(chan mesh.Message, inboxCapacity), clipboard: make(chan mesh.Message, inboxCapacity), done: make(chan struct{})}
	go i.run()
	return i
}

func (i *inbox) run() {
	defer close(i.done)
	for {
		message, err := i.transport.Receive(i.ctx)
		if err != nil {
			i.cancel(err)
			return
		}
		if i.ctx.Err() != nil {
			return
		}
		var target chan mesh.Message
		switch message.Topic {
		case replyTopic:
			target = i.replies
		case clipboardTopic:
			target = i.clipboard
		default:
			continue
		}
		select {
		case target <- message:
		default:
			i.cancel(ErrInboxOverflow)
			return
		}
	}
}

func (i *inbox) receive(ctx context.Context, source <-chan mesh.Message) (mesh.Message, error) {
	if err := i.ctx.Err(); err != nil {
		return mesh.Message{}, context.Cause(i.ctx)
	}
	select {
	case <-ctx.Done():
		return mesh.Message{}, context.Cause(ctx)
	case <-i.ctx.Done():
		return mesh.Message{}, context.Cause(i.ctx)
	case message := <-source:
		if i.ctx.Err() != nil {
			return mesh.Message{}, context.Cause(i.ctx)
		}
		if ctx.Err() != nil {
			return mesh.Message{}, context.Cause(ctx)
		}
		return message, nil
	}
}

func (i *inbox) Receive(ctx context.Context) (mesh.Message, error) { return i.receive(ctx, i.replies) }
func (i *inbox) close()                                            { i.cancel(context.Canceled); <-i.done }

//go:build ownerintegration

// SPDX-License-Identifier: MIT

package owner

import (
	"context"
	"sync/atomic"

	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/dispatcher"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/runtime/lua/engine"
	"github.com/wippyai/runtime/runtime/lua/engine/value"
)

// MakeTestAcceptCommand creates an acceptCommandPayload for testing.
func MakeTestAcceptCommand(ctx context.Context, owner pid.PID, width, height int) dispatcher.Command {
	var gen atomic.Uint64
	return &acceptCommandPayload{
		context:      ctx,
		frameContext: ctx,
		width:        width,
		height:       height,
		owner:        owner,
		topic:        "test-topic",
		epoch:        1,
		id:           1,
		generation:   &gen,
	}
}

// ActiveCount returns current active count.
func (m *Manager) ActiveCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.active)
}

// PendingCount returns current pending count.
func (m *Manager) PendingCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.pending
}

// OwnerCount returns number of active owners.
func (m *Manager) OwnerCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.owners)
}

// TestAttachmentHandleHelpers expose methods for native testing.
func CallAttachmentGrant(l *lua.LState) int {
	return attachmentGrant(l)
}

func CallAttachmentChannel(l *lua.LState) int {
	return attachmentChannel(l)
}

func CallAttachmentClose(l *lua.LState) int {
	return attachmentClose(l)
}

func MakeAttachmentHandleUD(l *lua.LState, owner pid.PID, epoch uint64, grant string, ch *engine.Channel, att *Attachment) *lua.LUserData {
	channelUD := engine.PushChannel(l, ch)
	l.Pop(1)
	handle := value.PushTypedUserData(l, &attachmentHandle{
		owner:      owner,
		epoch:      epoch,
		grant:      grant,
		channel:    ch,
		userdata:   channelUD,
		attachment: att,
	}, attachmentTypeName)
	l.Pop(1)
	return handle
}

func NewTestAttachment(manager *Manager, attGrant string, owner pid.PID, epoch uint64) *Attachment {
	serveCtx, serveCancel := context.WithCancel(context.Background())
	return &Attachment{
		manager:     manager,
		grant:       attGrant,
		owner:       owner,
		epoch:       epoch,
		serveCtx:    serveCtx,
		serveCancel: serveCancel,
		serveDone:   make(chan struct{}),
	}
}

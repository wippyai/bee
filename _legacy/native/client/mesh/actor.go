//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/relay"
	"unicode/utf8"
)

const maxMessageBytes = 16 * 1024
const maxMessages = 32

// Message preserves the logical relay sender from an authenticated owner-node
// ingress. Body is owned bounded JSON, not a borrowed scheduler payload. The
// operation decoder still validates request identity and the admitted process.
type Message struct {
	// From is the logical sender carried by the owner's relay envelope.
	From  pid.PID
	Topic string
	Body  json.RawMessage
}

// Actor is a single native process on the client's Wippy host. It can exchange
// bounded JSON control messages only with the enrolled owner node. Neither its
// PID nor a received message grants a viewport or application permission.
type Actor struct {
	ctx    context.Context
	id     pid.PID
	owner  string
	router relay.Receiver
	inbox  chan Message
	// pinned is the owner supervisor address the rendezvous descriptor
	// published. It is used instead of the cluster-wide name, which a
	// raft-disabled owner never registers.
	pinned pid.PID
}

func (a *Actor) PID() pid.PID { return a.id }

func validBody(topic string, body []byte) bool {
	return len(topic) > 0 && len(topic) <= 128 && utf8.ValidString(topic) && len(body) > 0 && len(body) <= maxMessageBytes && utf8.Valid(body) && json.Valid(body)
}

// Send supplies its own process identity and never replays a rejected send.
func (a *Actor) Send(ctx context.Context, target pid.PID, topic string, body []byte) error {
	if ctx == nil {
		return errors.New("mesh client: missing send context")
	}
	if err := a.ctx.Err(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if target.Node != a.owner || target.Host == "" || target.UniqID == "" || !validBody(topic, body) {
		return errors.New("mesh client: invalid owner request")
	}
	sender, ok := a.router.(relay.ContextSender)
	if !ok {
		return errors.New("mesh client: cancellable runtime router required")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(a.ctx, cancel)
	defer stop()
	pkg := relay.NewPackage(a.id, target, topic, payload.NewPayload(bytes.Clone(body), payload.JSON))
	msg := pkg.Messages[0]
	msg.PayloadBytes = int64(len(body))
	msg.MaxBytes = maxMessages * maxMessageBytes
	msg.MaxItems = maxMessages
	if err := sender.SendContext(ctx, pkg); err != nil {
		relay.ReleasePackage(pkg)
		return err
	}
	return nil
}

func (a *Actor) Receive(ctx context.Context) (Message, error) {
	if ctx == nil {
		return Message{}, errors.New("mesh client: missing receive context")
	}
	if err := a.ctx.Err(); err != nil {
		return Message{}, context.Cause(a.ctx)
	}
	select {
	case <-ctx.Done():
		return Message{}, ctx.Err()
	case <-a.ctx.Done():
		return Message{}, context.Cause(a.ctx)
	case message := <-a.inbox:
		if err := a.ctx.Err(); err != nil {
			return Message{}, context.Cause(a.ctx)
		}
		return message, nil
	}
}

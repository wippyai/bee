//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/runtime/api/pid"
)

var ownerPID = pid.PID{Node: "owner", Host: "bee.hive:supervisor_host", UniqID: "one"}

type scripted struct {
	sent      atomic.Int32
	lookups   atomic.Int32
	replaceAt int32
	body      chan wireCall
	replies   chan mesh.Message
}

func (s *scripted) OwnerSupervisor(ctx context.Context) (pid.PID, error) {
	if err := ctx.Err(); err != nil {
		return pid.PID{}, err
	}
	n := s.lookups.Add(1)
	p := ownerPID
	if s.replaceAt > 0 && n >= s.replaceAt {
		p.UniqID = "replacement"
	}
	return p, nil
}
func (s *scripted) Send(ctx context.Context, target pid.PID, topic string, raw []byte) error {
	if !samePID(target, ownerPID) || topic != requestTopic {
		return ErrProtocol
	}
	var call wireCall
	if strict(raw, &call) != nil || call.Revision != Revision || !canonicalTime(call.Deadline) {
		return ErrProtocol
	}
	s.sent.Add(1)
	select {
	case s.body <- call:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (s *scripted) Receive(ctx context.Context) (mesh.Message, error) {
	select {
	case r := <-s.replies:
		return r, nil
	case <-ctx.Done():
		return mesh.Message{}, ctx.Err()
	}
}
func fixture(t *testing.T) (*Client, *scripted, context.CancelFunc) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s := &scripted{body: make(chan wireCall, 8), replies: make(chan mesh.Message, 8)}
	client := newClient(ctx, s, "owner")
	t.Cleanup(client.Close)
	return client, s, cancel
}
func operation() Operation {
	return Operation{Owner: Owner{Node: "owner", Service: "bee.desktop"}, Ref: DesktopList, Key: "retained-key", Input: json.RawMessage(`{}`)}
}
func reply(id string) mesh.Message {
	body, _ := json.Marshal(map[string]any{"protocol_revision": Revision, "request_id": id, "ok": true, "value": map[string]any{}, "grants": map[string]any{}})
	return mesh.Message{From: ownerPID, Topic: replyTopic, Body: body}
}
func callContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	t.Cleanup(cancel)
	return ctx
}
func TestCallAuthenticatesSenderAndCorrelation(t *testing.T) {
	c, s, cancel := fixture(t)
	go func() {
		call := <-s.body
		wrong := reply(call.ID)
		wrong.From.UniqID = "sibling"
		s.replies <- wrong
		s.replies <- reply("old-request")
		s.replies <- reply(call.ID)
	}()
	r, err := c.Call(callContext(t), operation())
	if err != nil || !r.OK || s.sent.Load() != 1 || r.Done() != c.ctx.Done() {
		t.Fatalf("reply: %+v %v", r, err)
	}
	cancel()
	if _, err = c.Call(callContext(t), operation()); err == nil || s.sent.Load() != 1 {
		t.Fatal("sent after actor lifetime ended")
	}
}
func TestOwnerReplacementDuringCallIsUncertainAndRetiresClient(t *testing.T) {
	c, s, _ := fixture(t)
	s.replaceAt = 2
	go func() { call := <-s.body; s.replies <- reply(call.ID) }()
	_, err := c.Call(callContext(t), operation())
	var unknown *UnknownOutcome
	if !errors.As(err, &unknown) || !errors.Is(err, ErrOwner) || unknown.Key != operation().Key {
		t.Fatalf("replacement: %v", err)
	}
	if _, err = c.Call(callContext(t), operation()); !errors.Is(err, ErrOwner) || s.sent.Load() != 1 {
		t.Fatal("reused retired client")
	}
}
func TestOwnerReplacementBeforeNextCallDoesNotSend(t *testing.T) {
	c, s, _ := fixture(t)
	s.replaceAt = 3
	go func() { call := <-s.body; s.replies <- reply(call.ID) }()
	if _, err := c.Call(callContext(t), operation()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Call(callContext(t), operation()); !errors.Is(err, ErrOwner) || s.sent.Load() != 1 {
		t.Fatal("sent to replacement supervisor")
	}
}
func TestCancelAfterSendIsUnknownWithoutReplay(t *testing.T) {
	c, s, _ := fixture(t)
	ctx, cancel := context.WithCancel(callContext(t))
	go func() { <-s.body; cancel() }()
	_, err := c.Call(ctx, operation())
	var unknown *UnknownOutcome
	if !errors.As(err, &unknown) || !errors.Is(err, context.Canceled) || unknown.Operation != DesktopList || s.sent.Load() != 1 {
		t.Fatalf("cancel: %v", err)
	}
}
func TestCanceledGateWaitNeverSends(t *testing.T) {
	c, s, _ := fixture(t)
	c.gate <- struct{}{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := c.Call(ctx, operation())
	if !errors.Is(err, context.Canceled) || s.sent.Load() != 0 {
		t.Fatalf("gate: %v", err)
	}
}
func TestActorLifetimeCancelsPendingCall(t *testing.T) {
	c, s, cancel := fixture(t)
	go func() { <-s.body; cancel() }()
	_, err := c.Call(callContext(t), operation())
	var unknown *UnknownOutcome
	if !errors.As(err, &unknown) || !errors.Is(err, context.Canceled) || s.sent.Load() != 1 {
		t.Fatalf("actor cancellation: %v", err)
	}
}
func TestMalformedReplyRetiresClient(t *testing.T) {
	c, s, _ := fixture(t)
	go func() {
		call := <-s.body
		r := reply(call.ID)
		r.Body = []byte(`{"ok":true,"ok":true}`)
		s.replies <- r
	}()
	_, err := c.Call(callContext(t), operation())
	var unknown *UnknownOutcome
	if !errors.As(err, &unknown) || !errors.Is(err, ErrProtocol) {
		t.Fatalf("malformed: %v", err)
	}
	if _, err = c.Call(callContext(t), operation()); !errors.Is(err, ErrProtocol) || s.sent.Load() != 1 {
		t.Fatal("reused protocol-failed client")
	}
}

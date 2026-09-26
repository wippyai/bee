//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/mesh"
)

func answer(s *scripted, value any, fault map[string]any) {
	go func() {
		call := <-s.body
		body := map[string]any{"protocol_revision": Revision, "request_id": call.ID, "grants": map[string]any{}}
		if fault != nil {
			body["ok"], body["error"] = false, fault
		} else {
			body["ok"], body["value"] = true, value
		}
		raw, _ := json.Marshal(body)
		s.replies <- mesh.Message{From: ownerPID, Topic: replyTopic, Body: raw}
	}()
}

func joinFixture(t *testing.T) (*Join, *scripted) {
	t.Helper()
	client, s, _ := fixture(t)
	return &Join{client: client, owner: "owner"}, s
}

func TestJoinDecodesTheSupervisorInviteOperations(t *testing.T) {
	join, s := joinFixture(t)
	answer(s, map[string]any{"invite_id": strings.Repeat("a", 32), "secret": strings.Repeat("b", 64), "expires_at": "2026-09-23T12:15:00.000Z"}, nil)
	minted, err := join.Invite(callContext(t))
	if err != nil || minted.ID != strings.Repeat("a", 32) {
		t.Fatalf("invite = %+v, %v", minted, err)
	}
	// The Lua exporter spells an empty list as {}.
	answer(s, map[string]any{"invites": map[string]any{}}, nil)
	records, err := join.Invites(callContext(t))
	if err != nil || len(records) != 0 {
		t.Fatalf("empty invites = %v, %v", records, err)
	}
	answer(s, map[string]any{"invites": []any{map[string]any{"invite_id": minted.ID, "status": "used", "expires_at": minted.ExpiresAt, "node_id": "node-b"}}}, nil)
	records, err = join.Invites(callContext(t))
	if err != nil || len(records) != 1 || records[0].Node != "node-b" || records[0].Status != "used" {
		t.Fatalf("invites = %+v, %v", records, err)
	}
	answer(s, map[string]any{"node_id": "owner", "peers": []any{map[string]any{"node_id": "node-b", "session": "established"}}}, nil)
	view, err := join.Peers(callContext(t))
	if err != nil || view.Node != "owner" || len(view.Peers) != 1 || view.Peers[0].Session != "established" {
		t.Fatalf("peers = %+v, %v", view, err)
	}
	answer(s, nil, map[string]any{"code": "CONFLICT", "message": "invite was already used", "retryable": false})
	err = join.Redeem(callContext(t), minted.ID, minted.Secret, "node-c")
	var rejected *Rejected
	if !errors.As(err, &rejected) || rejected.Fault.Code != "CONFLICT" {
		t.Fatalf("redeem = %v", err)
	}
	answer(s, map[string]any{"invites": map[string]any{}, "extra": true}, nil)
	if _, err := join.Invites(callContext(t)); !errors.Is(err, ErrProtocol) {
		t.Fatalf("unknown field accepted: %v", err)
	}
}

func TestJoinCallsNameTheJoinServiceOfTheOwner(t *testing.T) {
	join, s := joinFixture(t)
	done := make(chan wireCall, 1)
	go func() {
		call := <-s.body
		done <- call
		raw, _ := json.Marshal(map[string]any{"protocol_revision": Revision, "request_id": call.ID, "ok": true, "grants": map[string]any{},
			"value": map[string]any{"invite_id": strings.Repeat("c", 32), "status": "revoked", "expires_at": "2026-09-23T12:15:00.000Z"}})
		s.replies <- mesh.Message{From: ownerPID, Topic: replyTopic, Body: raw}
	}()
	record, err := join.Revoke(context.Background(), strings.Repeat("c", 32))
	if err != nil || record.Status != "revoked" {
		t.Fatalf("revoke = %+v, %v", record, err)
	}
	call := <-done
	if call.Owner.Service != JoinService || call.Owner.Node != "owner" || call.Target.Ref != JoinRevoke || string(call.Input) != `{"invite_id":"`+strings.Repeat("c", 32)+`"}` {
		t.Fatalf("call = %+v", call)
	}
}

func TestOwnerStopNamesTheOwnerServiceAndDecodesItsAnswer(t *testing.T) {
	join, s := joinFixture(t)
	done := make(chan wireCall, 1)
	go func() {
		call := <-s.body
		done <- call
		raw, _ := json.Marshal(map[string]any{"protocol_revision": Revision, "request_id": call.ID, "ok": true, "grants": map[string]any{},
			"value": map[string]any{"stopping": false}})
		s.replies <- mesh.Message{From: ownerPID, Topic: replyTopic, Body: raw}
	}()
	stopping, err := StopOwner(context.Background(), join.client, true)
	if err != nil || stopping {
		t.Fatalf("stop = %v, %v", stopping, err)
	}
	call := <-done
	if call.Owner.Service != OwnerService || call.Owner.Node != "owner" || call.Target.Ref != OwnerStop || string(call.Input) != `{"alone":true}` {
		t.Fatalf("call = %+v", call)
	}
	answer(s, nil, map[string]any{"code": "DENIED", "message": "the host did not grant owner stop", "retryable": false})
	var rejected *Rejected
	if _, err := StopOwner(callContext(t), join.client, false); !errors.As(err, &rejected) || rejected.Fault.Code != "DENIED" {
		t.Fatalf("refused stop = %v", err)
	}
}

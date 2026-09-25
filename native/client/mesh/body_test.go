//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/relay"
)

func TestNativeControlBodyAcceptsNormalizedLuaRecords(t *testing.T) {
	body, ok := controlBody(payload.NewPayload(map[string]any{"request_id": "one", "values": []any{int64(7), true, nil}}, payload.Golang))
	if !ok || !json.Valid(body) {
		t.Fatal("normalized Lua record rejected")
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil || decoded["request_id"] != "one" {
		t.Fatalf("changed record: %s, %v", body, err)
	}
}

func TestNativeControlBodyBoundsNativeValuesBeforeEncoding(t *testing.T) {
	cycle := map[string]any{}
	cycle["self"] = cycle
	deep := any(true)
	for range 34 {
		deep = []any{deep}
	}
	for name, value := range map[string]any{
		"cycle": cycle, "deep": deep,
		"wide":              make([]any, maxMessageBytes+1),
		"large-string":      strings.Repeat("a", maxMessageBytes+1),
		"escaped-expansion": strings.Repeat("\x00", maxMessageBytes/2),
		"binary":            []byte("handle"), "native-handle": &struct{}{},
		"invalid-key": map[string]any{"\xff": true}, "invalid-text": "\xff", "nonfinite": math.Inf(1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, ok := controlBody(payload.NewPayload(map[string]any{"value": value}, payload.Golang)); ok {
				t.Fatal("invalid or oversized native value accepted")
			}
		})
	}
}

func TestNativeControlBodyRequiresObjectRoot(t *testing.T) {
	for _, value := range []any{nil, map[string]any(nil), []any{}, true, 1, "record"} {
		if _, ok := controlBody(payload.NewPayload(value, payload.Golang)); ok {
			t.Fatalf("accepted root %T", value)
		}
	}
	for _, value := range []string{"null", "[]", "true", "1", `"record"`, "{", "{} trailing"} {
		if _, ok := controlBody(payload.NewPayload([]byte(value), payload.JSON)); ok {
			t.Fatalf("accepted JSON root %q", value)
		}
	}
	if _, ok := controlBody(payload.NewPayload([]byte("  {}\n"), payload.JSON)); !ok {
		t.Fatal("valid object rejected")
	}
}

// Exercise the actual inbox boundary: accepting a map in an unused helper would
// still silently discard every Lua supervisor reply in the actor.
func TestActorDeliversNormalizedSupervisorReply(t *testing.T) {
	actor := &Actor{owner: "owner", inbox: make(chan Message, 1)}
	proc := &nativeActor{actor: actor}
	sender := pid.PID{Node: "owner", Host: "bee.hive.service:supervisor_host", UniqID: "one"}
	pkg := relay.NewPackage(sender, pid.PID{}, "bee.hive.reply", payload.NewPayload(map[string]any{"request_id": "one", "ok": true}, payload.Golang))
	var output process.StepOutput
	if err := proc.Step([]process.Event{{Type: process.EventMessage, Data: pkg}}, &output); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-actor.inbox:
		var record map[string]any
		if message.From != sender || message.Topic != "bee.hive.reply" || json.Unmarshal(message.Body, &record) != nil || record["request_id"] != "one" || record["ok"] != true {
			t.Fatalf("changed supervisor reply: %+v", message)
		}
	default:
		t.Fatal("normalized supervisor reply silently discarded")
	}
}

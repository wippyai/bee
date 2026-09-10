//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestReplyMatchesLuaEmptyListAndTypedFault(t *testing.T) {
	for _, raw := range []string{
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":false,"error":{"code":"DESKTOP_CONTROLLED","message":"already controlled","retryable":false},"grants":{}}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":false,"error":{"code":"LIMIT_EXCEEDED","message":"desktop capacity","retryable":false},"grants":{}}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":true,"value":{},"grants":{}}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":true,"value":null,"grants":[]}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":false,"error":{"code":"UNCERTAIN","message":"disconnected","retryable":false,"identity":{"operation_ref":"op","idempotency_key":"key"}},"grants":{}}`,
	} {
		if _, err := decodeReply([]byte(raw)); err != nil {
			t.Fatalf("valid Lua reply rejected: %s: %v", raw, err)
		}
	}
}
func TestReplyRejectsMalformedAndAmbiguousRecords(t *testing.T) {
	base := `{"protocol_revision":"bee.hive@1","request_id":"r","ok":true,"value":{},"grants":[]}`
	for _, raw := range []string{
		"null", "[]", "{}", strings.Replace(base, `"ok":true`, `"ok":null`, 1),
		strings.Replace(base, `"ok":true`, `"ok":true,"ok":false`, 1),
		strings.Replace(base, `"value":{}`, `"value":{"x":1,"x":2}`, 1),
		strings.Replace(base, `"grants":[]`, `"grants":{"grant_id":"forged"}`, 1),
		strings.Replace(base, `"grants":[]`, `"grants":[null]`, 1),
		strings.Replace(base, `"request_id":"r"`, `"request_id":null`, 1),
		strings.Replace(base, `"ok":true`, `"ok":true,"unknown":1`, 1),
		strings.Replace(base, `"ok":true`, `"ok":false`, 1),
		strings.Replace(base, `"value":{}`, `"error":{"code":"DENIED","message":"no","retryable":false}`, 1),
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":false,"error":{"code":"DENIED","message":"no","retryable":null}}`,
		base + "null", strings.Repeat(" ", maxBytes) + base,
	} {
		if _, err := decodeReply([]byte(raw)); err == nil {
			t.Fatalf("malformed reply accepted (%d bytes): %.200s", len(raw), raw)
		}
	}
}
func TestReplyValidatesGrantOwnersAndExpiry(t *testing.T) {
	grant := Grant{ID: "g", Owner: Owner{Node: "owner", Service: "bee.desktop"}, Epoch: 1, Expires: "2026-09-09T12:00:00.000Z"}
	encode := func(g Grant) []byte {
		b, _ := json.Marshal(map[string]any{"protocol_revision": Revision, "request_id": "r", "ok": true, "grants": []Grant{g}})
		return b
	}
	if _, err := decodeReply(encode(grant)); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"owner", "epoch", "expiry"} {
		bad := grant
		switch field {
		case "owner":
			bad.Owner.Node = ""
		case "epoch":
			bad.Epoch = 0
		case "expiry":
			bad.Expires = "tomorrow"
		}
		if _, err := decodeReply(encode(bad)); err == nil {
			t.Fatalf("bad grant %s accepted", field)
		}
	}
}

func TestGrantRejectsExplicitEmptyOptionalResource(t *testing.T) {
	raw := []byte(`{"protocol_revision":"bee.hive@1","request_id":"r","ok":true,"grants":[{"grant_id":"g","issuer_owner_ref":{"node_id":"owner","service_id":"desktop","resource_ref":""},"authorization_epoch":1,"expires_at":"2026-09-09T12:00:00.000Z"}]}`)
	if _, err := decodeReply(raw); err == nil {
		t.Fatal("empty resource accepted")
	}
}

func TestReplyRejectsCaseAliasedFields(t *testing.T) {
	for _, raw := range []string{
		`{"protocol_revision":"bee.hive@1","request_id":"r","OK":true}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":false,"error":{"Code":"DENIED","message":"no","retryable":false}}`,
		`{"protocol_revision":"bee.hive@1","request_id":"r","ok":true,"grants":[{"Grant_id":"g","issuer_owner_ref":{"node_id":"owner","service_id":"desktop"},"authorization_epoch":1,"expires_at":"2026-09-09T12:00:00.000Z"}]}`,
	} {
		if _, err := decodeReply([]byte(raw)); err == nil {
			t.Fatalf("accepted aliased reply: %s", raw)
		}
	}
}

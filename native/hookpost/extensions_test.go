// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

func TestRunToCapturesVerifiedDriverHookDecisions(t *testing.T) {
	t.Setenv("BEE_HOOK_TEST_TOKEN", "fixture-hook-token")
	cases := []struct{ name, event, input, reply string }{
		{"agy-deny", "agy:PreToolUse", `{"conversationId":"s","stepIdx":7,"toolCall":{"name":"shell","args":{"command":"pwd"}}}`, `{"decision":"deny","reason":"refused"}`},
		{"agy-overwrite", "agy:PreToolUse", `{"conversationId":"s","stepIdx":8,"toolCall":{"name":"shell","args":{"command":"pwd"}}}`, `{"overwrite":{"command":"ls"}}`},
		{"muse-deny", "PreToolUse", `{"session_id":"s","tool_name":"shell","tool_input":{"command":"pwd"}}`, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"refused"}}`},
		{"muse-rewrite", "PreToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"ls"}}}`},
		{"muse-after-context", "PostToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"remember"}}`},
		{"grok-prompt-deny", "UserPromptSubmit", `{"session_id":"s"}`, `{"decision":"block","reason":"refused"}`},
		{"grok-rewrite", "PreToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"ls"},"additionalContext":"context"}}`},
		{"grok-output", "PostToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":{"result":"digest"}}}`},
		{"pass", "PreToolUse", `{"session_id":"s"}`, `{}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var captured map[string]json.RawMessage
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
					t.Error(err)
				}
				_, _ = io.WriteString(w, tc.reply)
			}))
			defer server.Close()
			var out strings.Builder
			err := RunTo(context.Background(), io.NopCloser(strings.NewReader(tc.input)), &out, strings.TrimPrefix(server.URL, "http://"), "action", "BEE_HOOK_TEST_TOKEN", tc.event)
			if err != nil {
				t.Fatal(err)
			}
			var result map[string]json.RawMessage
			if json.Unmarshal([]byte(out.String()), &result) != nil {
				t.Fatalf("no response captured: %q", out.String())
			}
			var expected, actual any
			_ = json.Unmarshal([]byte(tc.reply), &expected)
			_ = json.Unmarshal([]byte(out.String()), &actual)
			if !reflect.DeepEqual(actual, expected) {
				t.Fatalf("response = %s, want %s", mustJSON(result), mustJSON(expected))
			}
			if captured["hook_event_name"] == nil {
				t.Fatal("occurrence not delivered")
			}
			if strings.HasPrefix(tc.event, "agy:") && (string(captured["tool_call_id"]) != `"7"` && string(captured["tool_call_id"]) != `"8"`) {
				t.Fatal("Agy step identity lost")
			}
		})
	}
}

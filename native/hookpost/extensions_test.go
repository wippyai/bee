// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Each driver's hook answer reaches its CLI as the gateway wrote it.
func TestRunToCarriesEachDriverAnswerUnchanged(t *testing.T) {
	t.Setenv("BEE_HOOK_TEST_TOKEN", "fixture-hook-token")
	cases := []struct{ name, event, input, reply string }{
		{"agy-deny", "agy:PreToolUse", `{"conversationId":"s","stepIdx":7,"toolCall":{"name":"shell","args":{"command":"pwd"}}}`, `{"decision":"deny","reason":"refused"}`},
		{"agy-overwrite", "agy:PreToolUse", `{"conversationId":"s","stepIdx":8,"toolCall":{"name":"shell","args":{"command":"pwd"}}}`, `{"overwrite":{"command":"ls"}}`},
		{"muse-deny", "PreToolUse", `{"session_id":"s","tool_name":"shell","tool_input":{"command":"pwd"}}`, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"refused"}}`},
		{"muse-rewrite", "PreToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"ls"}}}`},
		{"grok-prompt-deny", "UserPromptSubmit", `{"session_id":"s"}`, `{"decision":"block","reason":"refused"}`},
		{"grok-output", "PostToolUse", `{"session_id":"s"}`, `{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":{"result":"digest"}}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var body []byte
			var event string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ = io.ReadAll(r.Body)
				event = r.Header.Get(EventHeader)
				_, _ = io.WriteString(w, tc.reply)
			}))
			defer server.Close()
			var out strings.Builder
			err := RunTo(context.Background(), io.NopCloser(strings.NewReader(tc.input)), &out, strings.TrimPrefix(server.URL, "http://"), "action", "BEE_HOOK_TEST_TOKEN", tc.event)
			if err != nil {
				t.Fatal(err)
			}
			if out.String() != tc.reply+"\n" || string(body) != tc.input || event != tc.event {
				t.Fatalf("answer %s, body %s, event %s", out.String(), body, event)
			}
		})
	}
}

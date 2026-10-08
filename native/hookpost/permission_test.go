// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPermissionHookDecisionRoundTrip(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	for _, decision := range []string{"allow", "deny"} {
		t.Run(decision, func(t *testing.T) {
			response := `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"` + decision + `","message":"fixture reason"}}}`
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/hook/action" || r.Header.Get("Authorization") != "Bearer fixture-hook-token" {
					t.Error("wrong hook boundary")
				}
				_, _ = io.Copy(io.Discard, r.Body)
				_, _ = io.WriteString(w, response)
			}))
			defer server.Close()
			var output strings.Builder
			err := RunTo(context.Background(), io.NopCloser(strings.NewReader(`{"tool_name":"bash","tool_input":{"command":"printf fixture"}}`)), &output, strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "PermissionRequest")
			if err != nil || strings.TrimSpace(output.String()) != response {
				t.Fatalf("decision was not delivered: %v %s", err, output.String())
			}
		})
	}
}

func TestPermissionHookWithoutHostExchangeRetainsProviderDecision(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{ }`)
	}))
	defer server.Close()
	var output strings.Builder
	err := RunTo(context.Background(), io.NopCloser(strings.NewReader(`{"tool_name":"bash","tool_input":{}}`)), &output,
		strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "PermissionRequest")
	if err != nil || output.Len() != 0 {
		t.Fatalf("provider-owned decision became a hook failure: %v", err)
	}
}

func TestAgyPermissionGateUsesBeeHookDecision(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload map[string]any
		if json.NewDecoder(r.Body).Decode(&payload) != nil || payload["hook_event_name"] != "PermissionRequest" ||
			payload["session_id"] != "fixture-session" || payload["tool_name"] != "run_command" {
			t.Error("Agy permission did not reach the common hook shape")
		}
		_, _ = io.WriteString(w, `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"person approved"}}}`)
	}))
	defer server.Close()
	var output strings.Builder
	err := RunTo(context.Background(), io.NopCloser(strings.NewReader(`{"conversationId":"fixture-session","stepIdx":19,"toolCall":{"name":"run_command","args":{"CommandLine":"printf fixture-tool"}}}`)),
		&output, strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "agy:PermissionRequest")
	if err != nil {
		t.Fatal(err)
	}
	var decision map[string]any
	if json.Unmarshal([]byte(output.String()), &decision) != nil || decision["decision"] != "allow" || decision["reason"] != "person approved" {
		t.Fatalf("wrong Agy permission response: %s", output.String())
	}
}

func TestPermissionHookRejectsMalformedDecisions(t *testing.T) {
	for _, response := range []string{
		`null`,
		`{"hookSpecificOutput":null}`,
		`{"hookSpecificOutput":{"hookEventName":"Stop","decision":{"behavior":"allow"}}}`,
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"approve"}}}`,
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","extra":"value"}}}`,
		`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}{}`,
	} {
		var output strings.Builder
		if err := permissionResponse([]byte(response), &output); err == nil || output.Len() != 0 {
			t.Fatalf("accepted malformed decision: %v", err)
		}
	}
}

func TestPermissionHookCancellationInterruptsDecisionWait(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	requested := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(requested)
		<-release
	}))
	defer server.Close()
	defer close(release)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		finished <- RunTo(ctx, io.NopCloser(strings.NewReader(`{"tool_name":"bash","tool_input":{}}`)), io.Discard,
			strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "PermissionRequest")
	}()
	select {
	case <-requested:
	case <-time.After(time.Second):
		t.Fatal("permission request did not arrive")
	}
	cancel()
	select {
	case err := <-finished:
		if err != context.Canceled {
			t.Fatalf("wait did not return cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("permission wait outlived cancellation")
	}
}

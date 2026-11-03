// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
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
		_, _ = io.Copy(io.Discard, r.Body)
	}))
	defer server.Close()
	var output strings.Builder
	err := RunTo(context.Background(), io.NopCloser(strings.NewReader(`{"tool_name":"bash","tool_input":{}}`)), &output,
		strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "PermissionRequest")
	if err != nil || output.Len() != 0 {
		t.Fatalf("provider-owned decision became a hook failure: %v", err)
	}
}

// A driver-qualified permission gate reaches the gateway as the CLI wrote it
// and waits as long as any permission; the gateway reads and answers it.
func TestQualifiedPermissionGateReachesTheGatewayUnchanged(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	input := `{"conversationId":"fixture-session","stepIdx":19,"toolCall":{"name":"run_command","args":{"CommandLine":"printf fixture-tool"}}}`
	answer := `{"decision":"allow","reason":"person approved"}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if string(body) != input || r.Header.Get(EventHeader) != "agy:PermissionRequest" {
			t.Error("qualified permission did not reach the gateway unchanged")
		}
		_, _ = io.WriteString(w, answer)
	}))
	defer server.Close()
	var output strings.Builder
	err := RunTo(context.Background(), io.NopCloser(strings.NewReader(input)),
		&output, strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "agy:PermissionRequest")
	if err != nil || output.String() != answer+"\n" {
		t.Fatalf("wrong permission answer: %v %s", err, output.String())
	}
	if event, _ := commandEvent("agy:PermissionRequest"); requestTimeout(event) != PermissionTimeout {
		t.Fatal("a qualified permission does not wait for the person")
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

// A host answers a permission within ten minutes, an expired request
// included; the hook waits past that so the answer reaches the agent.
func TestPermissionHookWaitsPastTheHostAnswerWindow(t *testing.T) {
	if requestTimeout("PermissionRequest") <= 10*time.Minute {
		t.Fatalf("permission hook gives up after %s", requestTimeout("PermissionRequest"))
	}
	if requestTimeout("Stop") != RequestTimeout {
		t.Fatalf("observation hook deadline is %s", requestTimeout("Stop"))
	}
}

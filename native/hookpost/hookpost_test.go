// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type blockingInput struct {
	closed chan struct{}
}

func newBlockingInput() *blockingInput { return &blockingInput{closed: make(chan struct{})} }
func (b *blockingInput) Read([]byte) (int, error) {
	<-b.closed
	return 0, io.ErrClosedPipe
}
func (b *blockingInput) Close() error {
	select {
	case <-b.closed:
	default:
		close(b.closed)
	}
	return nil
}

func TestRunCancelsBlockedStdin(t *testing.T) {
	t.Setenv("BEE_TOKEN", "stdin-test-token")
	input := newBlockingInput()
	started := time.Now()
	err := Run(context.Background(), input, "127.0.0.1:1", "action", "BEE_TOKEN", "Stop")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Run error = %v, want deadline", err)
	}
	if elapsed := time.Since(started); elapsed > RequestTimeout+500*time.Millisecond {
		t.Fatalf("blocked stdin took %s to cancel", elapsed)
	}
	select {
	case <-input.closed:
	default:
		t.Fatal("stdin was not closed on cancellation")
	}
}

func TestRunPeerTimeoutAndCancellation(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer server.Close()
	defer close(release)
	endpoint := strings.TrimPrefix(server.URL, "http://")
	t.Setenv("BEE_TOKEN", "token-for-peer-timeout")
	started := time.Now()
	err := Run(context.Background(), io.NopCloser(strings.NewReader(`{"session_id":"s"}`)), endpoint, "action", "BEE_TOKEN", "Stop")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Run error = %v, want deadline", err)
	}
	if elapsed := time.Since(started); elapsed > RequestTimeout+500*time.Millisecond {
		t.Fatalf("peer timeout took %s", elapsed)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = Run(ctx, io.NopCloser(strings.NewReader(`{"session_id":"s"}`)), endpoint, "action", "BEE_TOKEN", "Stop")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled Run error = %v", err)
	}
}

func TestRunPostsGenericPayloadAndOnlyAcceptsSuccess(t *testing.T) {
	var calls atomic.Int32
	var received map[string]json.RawMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/hook/action:request-1" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer hook-secret" {
			t.Errorf("authorization = %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	t.Setenv("BEE_TOKEN", "hook-secret")
	err := Run(context.Background(), io.NopCloser(strings.NewReader(`{"session_id":"s1","tool_input":{"secret":"raw"},"hook_event_name":"Stop"}`)), strings.TrimPrefix(server.URL, "http://"), "action:request-1", "BEE_TOKEN", "Stop")
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want one", calls.Load())
	}
	if string(received["hook_event_name"]) != `"Stop"` || string(received["session_id"]) != `"s1"` || received["tool_input"] == nil {
		t.Fatalf("payload = %s", mustJSON(received))
	}
}

func TestRunReadsTokenFromPrivateJSONFile(t *testing.T) {
	const secret = "file-hook-secret"
	path := t.TempDir() + "/hook-token.json"
	if err := os.WriteFile(path, []byte(`{"token":"`+secret+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var authorization string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	if err := Run(context.Background(), io.NopCloser(strings.NewReader(`{"session_id":"file-session"}`)), strings.TrimPrefix(server.URL, "http://"), "action", "@"+path, "SessionStart"); err != nil {
		t.Fatal(err)
	}
	if authorization != "Bearer "+secret {
		t.Fatalf("authorization = %q", authorization)
	}
}

func TestRunRejectsInvalidTokenFilesWithoutFallbackOrDiagnostics(t *testing.T) {
	const secret = "file-secret-that-must-not-escape"
	setenvName := "BEE_TOKEN_FILE_FALLBACK"
	t.Setenv(setenvName, secret)
	cases := []struct {
		name    string
		content string
	}{
		{name: "malformed", content: `{"token":`},
		{name: "unknown field", content: `{"token":"` + secret + `","extra":true}`},
		{name: "multiple documents", content: `{"token":"` + secret + `"}{}`},
		{name: "missing token", content: `{}`},
		{name: "wrong token type", content: `{"token":42}`},
		{name: "duplicate token", content: `{"token":"one","token":"two"}`},
		{name: "wrong top level", content: `[]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := t.TempDir() + "/hook-token.json"
			if err := os.WriteFile(path, []byte(tc.content), 0o600); err != nil {
				t.Fatal(err)
			}
			err := Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", "@"+path, "Stop")
			if err == nil {
				t.Fatal("Run accepted invalid token file")
			}
			if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), path) {
				t.Fatalf("diagnostic leaked credential or path: %v", err)
			}
		})
	}

	missing := t.TempDir() + "/missing-token.json"
	err := Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", "@"+missing, "Stop")
	if err == nil {
		t.Fatal("Run fell back after a missing token file")
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), missing) {
		t.Fatalf("diagnostic leaked credential or path: %v", err)
	}
}

func TestRunRejectsTokenSourcesOutsideBoundsOrRegularFiles(t *testing.T) {
	t.Setenv("BEE_TOKEN_FILE_FALLBACK", "fallback-secret")
	cases := []struct {
		name   string
		source string
	}{
		{name: "relative file", source: "@relative-token.json"},
		{name: "empty file path", source: "@"},
		{name: "path bound", source: "@/" + strings.Repeat("x", MaxTokenPathBytes)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", tc.source, "Stop")
			if err == nil {
				t.Fatal("Run accepted invalid token source")
			}
			if strings.Contains(err.Error(), tc.source) {
				t.Fatalf("diagnostic leaked token source: %v", err)
			}
		})
	}

	directory := t.TempDir()
	err := Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", "@"+directory, "Stop")
	if err == nil {
		t.Fatal("Run accepted a directory as the token file")
	}

	target := t.TempDir() + "/target.json"
	if err := os.WriteFile(target, []byte(`{"token":"symlink-secret"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := t.TempDir() + "/hook-token.json"
	if err := os.Symlink(target, symlink); err != nil {
		t.Fatal(err)
	}
	err = Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", "@"+symlink, "Stop")
	if err == nil {
		t.Fatal("Run accepted a symlink as the token file")
	}

	oversized := t.TempDir() + "/oversized-token.json"
	if err := os.WriteFile(oversized, []byte(strings.Repeat("x", MaxTokenFileBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	err = Run(context.Background(), io.NopCloser(strings.NewReader(`{}`)), "127.0.0.1:1", "action", "@"+oversized, "Stop")
	if err == nil {
		t.Fatal("Run accepted an oversized token file")
	}
}

func TestRunDoesNotFollowRedirectOrLeakCredentials(t *testing.T) {
	var redirected atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { redirected.Add(1) }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", target.URL+"/hook/action")
		w.WriteHeader(http.StatusTemporaryRedirect)
		_, _ = w.Write([]byte("token-secret payload-secret"))
	}))
	defer server.Close()
	t.Setenv("BEE_TOKEN", "token-secret")
	err := Run(context.Background(), io.NopCloser(strings.NewReader(`{"secret":"payload-secret"}`)), strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "Stop")
	if err == nil || !strings.Contains(err.Error(), "status 307") {
		t.Fatalf("redirect error = %v", err)
	}
	if strings.Contains(err.Error(), "token-secret") || strings.Contains(err.Error(), "payload-secret") {
		t.Fatalf("error leaked secret: %v", err)
	}
	if redirected.Load() != 0 {
		t.Fatal("redirect target received a request")
	}
}

func TestRunRejectsMalformedBoundsAndEventConflicts(t *testing.T) {
	t.Setenv("BEE_TOKEN", "token")
	cases := []struct {
		name, endpoint, action, tokenEnv, event, input string
	}{
		{"endpoint host", "localhost:1234", "action", "BEE_TOKEN", "Stop", `{}`},
		{"endpoint port", "127.0.0.1:65536", "action", "BEE_TOKEN", "Stop", `{}`},
		{"action", "127.0.0.1:1234", "../action", "BEE_TOKEN", "Stop", `{}`},
		{"event", "127.0.0.1:1234", "action", "BEE_TOKEN", "Unknown", `{}`},
		{"environment", "127.0.0.1:1234", "action", "bad-name", "Stop", `{}`},
		{"malformed", "127.0.0.1:1234", "action", "BEE_TOKEN", "Stop", `{`},
		{"multiple documents", "127.0.0.1:1234", "action", "BEE_TOKEN", "Stop", `{} {}`},
		{"event conflict", "127.0.0.1:1234", "action", "BEE_TOKEN", "Stop", `{"hook_event_name":"PreToolUse"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := Run(context.Background(), io.NopCloser(strings.NewReader(tc.input)), tc.endpoint, tc.action, tc.tokenEnv, tc.event)
			if err == nil {
				t.Fatal("Run succeeded")
			}
			if strings.Contains(err.Error(), "token") && tc.name != "environment" && tc.name != "event conflict" {
				t.Fatalf("unexpected sensitive error: %v", err)
			}
		})
	}
	oversize := strings.Repeat("x", MaxPayloadBytes+1)
	if err := Run(context.Background(), io.NopCloser(strings.NewReader(oversize)), "127.0.0.1:1234", "action", "BEE_TOKEN", "Stop"); err == nil {
		t.Fatal("oversize input succeeded")
	}
}

func mustJSON(value any) string {
	data, _ := json.Marshal(value)
	return string(data)
}

func TestRunCancelsActualPipeRead(t *testing.T) {
	t.Setenv("BEE_TOKEN", "pipe-test-token")
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = Run(ctx, reader, "127.0.0.1:1", "action", "BEE_TOKEN", "Stop")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Run = %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("pipe read did not cancel promptly")
	}
}

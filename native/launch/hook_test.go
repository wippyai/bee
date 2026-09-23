// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

// A hook process runs inside a harness with a short deadline. Its launch posts
// one event and never selects a project, reads state or reaches the owner.
func TestPlanRunsHookPostBeforeProjectSelectionAndClientRoute(t *testing.T) {
	type received struct {
		path, authorization string
		body                map[string]any
	}
	requests := make(chan received, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		if err := json.Unmarshal(data, &body); err != nil {
			t.Errorf("hook body is not JSON: %v", err)
		}
		requests <- received{path: r.URL.Path, authorization: r.Header.Get("Authorization"), body: body}
		w.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	endpoint := strings.TrimPrefix(server.URL, "http://")

	// The state root is a regular file and the working directory does not exist,
	// so any project selection or state read fails the launch.
	base := t.TempDir()
	state := filepath.Join(base, "state")
	if err := os.WriteFile(state, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(base, "missing")
	host, err := newHost(state, systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("BEE_TEST_HOOK_TOKEN", "hook-secret")

	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing,
		Args: []string{"hook-post", endpoint, "action-1", "BEE_TEST_HOOK_TOKEN", "PreToolUse"},
	})
	if err != nil {
		t.Fatalf("hook-post planning touched project selection: %v", err)
	}
	if plan.Run == nil || plan.Prepare != nil || plan.DefaultState != "" || plan.Command != "" || plan.Args != nil {
		t.Fatalf("hook-post plan = %#v", plan)
	}
	if host.ownerState != "" {
		t.Fatalf("hook-post selected owner state %q", host.ownerState)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin := os.Stdin
	os.Stdin = reader
	t.Cleanup(func() { os.Stdin = stdin })
	if _, err := writer.WriteString(`{"tool_name":"Bash"}`); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	if err := plan.Run(context.Background()); err != nil {
		t.Fatalf("hook-post run: %v", err)
	}
	select {
	case request := <-requests:
		if request.path != "/hook/action-1" || request.authorization != "Bearer hook-secret" {
			t.Fatalf("hook request = %q %q", request.path, request.authorization)
		}
		if request.body["hook_event_name"] != "PreToolUse" || request.body["tool_name"] != "Bash" {
			t.Fatalf("hook body = %#v", request.body)
		}
	default:
		t.Fatal("hook-post did not post the event")
	}
	info, err := os.Stat(state)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("hook-post changed the state root: %v", err)
	}
	if _, err := os.Stat(missing); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("hook-post created the working directory: %v", err)
	}
}

func TestPlanRefusesMalformedHookPost(t *testing.T) {
	host, err := newHost(filepath.Join(t.TempDir(), "state"), systemHostResolver())
	if err != nil {
		t.Fatal(err)
	}
	_, err = host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, State: t.TempDir(), Dir: filepath.Join(t.TempDir(), "missing"),
		Args: []string{"hook-post", "127.0.0.1:1", "action-1", "TOKEN"},
	})
	if err == nil || !strings.Contains(err.Error(), "hook-post: expected ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT") {
		t.Fatalf("malformed hook-post error = %v", err)
	}
}

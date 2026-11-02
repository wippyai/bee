// SPDX-License-Identifier: MIT

package hookpost

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// capturedPayload reads one captured hook payload and restores every string
// the fixture kept as a prefix to its captured length.
func capturedPayload(t *testing.T, directory, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(directory, name))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	var truncated map[string]map[string]int
	if data, err := os.ReadFile(filepath.Join(directory, "truncated.json")); err == nil {
		if err := json.Unmarshal(data, &truncated); err != nil {
			t.Fatal(err)
		}
	}
	for path, length := range truncated[name] {
		key := strings.TrimPrefix(path, "/")
		prefix, ok := fields[key].(string)
		if !ok || strings.Contains(key, "/") {
			t.Fatalf("%s: unsupported truncated path %s", name, path)
		}
		fields[key] = prefix + strings.Repeat("x", length-len(prefix))
	}
	encoded, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

// A command-hook CLI sends a tool's whole result with PostToolUse; Muse 1.4.14
// sent 100000 bytes of a read_file result in one captured turn.
func TestRunForwardsCapturedPostToolUseWithItsWholeToolResult(t *testing.T) {
	t.Setenv("BEE_TOKEN", "fixture-hook-token")
	payload := capturedPayload(t, "../../drivers/test/fixtures/drivers/muse/hooks-1.4.14", "13-PostToolUse.json")
	if len(payload) <= 100000 {
		t.Fatalf("captured payload is %d bytes", len(payload))
	}
	var received map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode body: %v", err)
		}
	}))
	defer server.Close()
	var output strings.Builder
	err := RunTo(context.Background(), io.NopCloser(strings.NewReader(string(payload))), &output,
		strings.TrimPrefix(server.URL, "http://"), "action", "BEE_TOKEN", "PostToolUse")
	if err != nil {
		t.Fatal(err)
	}
	if response, _ := received["tool_response"].(string); len(response) != 100000 {
		t.Fatalf("gateway received a %d-byte tool_response", len(response))
	}
}

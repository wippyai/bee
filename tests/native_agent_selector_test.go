// SPDX-License-Identifier: MIT
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func applyTestFrame(d *desktop, content string) {
	d.pending = append(d.pending, []byte(frameStart+content+frameEnd)...)
	d.consumeFrames()
}

func TestConsumeFramesRetainsAndErasesCurrentScreenRows(t *testing.T) {
	d := &desktop{screen: newTerminalScreen(100, 30)}
	applyTestFrame(d, "\x1b[2J\x1b[1;1HAntigravity\r\nClaude\r\nCodex\r\nGrok")
	latest, frame := d.latest, d.frame
	if frame != 1 {
		t.Fatalf("initial frame count = %d, want 1", frame)
	}
	for _, text := range []string{"Antigravity", "Claude", "Codex", "Grok"} {
		if !strings.Contains(latest, text) {
			t.Fatalf("initial screen omitted %q: %q", text, latest)
		}
	}

	// A presenter update can repaint one row only. Unchanged rows must survive
	// the update, while EL must remove the old longer label from the changed row.
	applyTestFrame(d, "\x1b[2;1H\x1b[2KClaude unavailable")
	latest, frame = d.latest, d.frame
	if frame != 2 {
		t.Fatalf("partial frame count = %d, want 2", frame)
	}
	if !strings.Contains(latest, "Codex") || !strings.Contains(latest, "Grok") {
		t.Fatalf("partial frame lost unchanged rows: %q", latest)
	}
	if !strings.Contains(latest, "Claude unavailable") {
		t.Fatalf("partial frame omitted changed row: %q", latest)
	}

	applyTestFrame(d, "\x1b[2;1H\x1b[2KClaude")
	latest = d.latest
	if strings.Contains(latest, "unavailable") {
		t.Fatalf("erase-left stale text on current screen: %q", latest)
	}
	if !strings.Contains(latest, "Codex") {
		t.Fatalf("second partial frame lost Codex: %q", latest)
	}
}

func TestConsumeFramesPreservesUnicodeInPartialUpdates(t *testing.T) {
	d := &desktop{screen: newTerminalScreen(100, 30)}
	applyTestFrame(d, "\x1b[1;1H选择 Codex")
	applyTestFrame(d, "\x1b[1;1H\x1b[2K选择 Codex")
	latest, frame := d.latest, d.frame
	if frame != 2 || !strings.Contains(latest, "选择 Codex") {
		t.Fatalf("Unicode current screen = (%d, %q), want retained text", frame, latest)
	}
}

// Agy 1.2.2 sends these placeholders literally; the fixture must not make an
// unsupported credential configuration pass by expanding them itself.
func TestAgyMCPHeaderRemainsLiteral(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("BEE_TEST_TOKEN", "resolved-token")
	customizationRoot := t.TempDir()
	dir := filepath.Join(customizationRoot, ".agents")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	data := `{"mcpServers":{"bee":{"serverUrl":"http://127.0.0.1:1234/mcp/action:test","headers":{"Authorization":"Bearer ${BEE_TEST_TOKEN}"}}}}`
	if err := os.WriteFile(filepath.Join(dir, "mcp_config.json"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	_, token, ok := mcpProbeConfig("agy", []string{"--add-dir", customizationRoot})
	if !ok || token != "${BEE_TEST_TOKEN}" {
		t.Fatal("fixture changed Agy literal header semantics")
	}
}

func TestGrokMCPProbeSelectsOnlyBeeHeader(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("BEE_TEST_TOKEN", "selected-fixture-token")
	t.Setenv("OTHER_TOKEN", "unrelated-fixture-token")
	dir := filepath.Join(home, ".grok")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	config := `[mcp_servers.bee]
url = "http://127.0.0.1:1234/mcp/action"
[mcp_servers.bee.headers]
Authorization = "Bearer ${BEE_TEST_TOKEN}"
[mcp_servers.other]
url = "http://127.0.0.1:4567/mcp/other"
[mcp_servers.other.headers]
Authorization = "Bearer ${OTHER_TOKEN}"
`
	if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	url, token, ok := mcpProbeConfig("grok", nil)
	if !ok || url != "http://127.0.0.1:1234/mcp/action" || token != "selected-fixture-token" {
		t.Fatal("probe selected unrelated MCP configuration")
	}
}

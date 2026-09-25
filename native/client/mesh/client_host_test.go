//go:build meshclient

// SPDX-License-Identifier: MIT

package mesh

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The owner's desktop bridge admits native desktop calls only from its client
// host (src/hive/desktop/protocol.lua CLIENT_HOST), so the physical client's
// actor must speak from exactly that host.
func TestActorHostIsTheDesktopBridgeClientHost(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "src", "hive", "desktop", "protocol.lua"))
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`(?m)^M\.CLIENT_HOST = "([^"]+)"$`).FindSubmatch(source)
	if match == nil {
		t.Fatal("desktop protocol declares no client host")
	}
	if ActorHost != string(match[1]) {
		t.Fatalf("actor host = %q, desktop bridge admits %q", ActorHost, match[1])
	}
}

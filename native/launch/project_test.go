//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestProjectStateDirsAreDistinctAndCanonical(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first")
	second := filepath.Join(root, "second")
	for _, directory := range []string{first, second} {
		if err := os.Mkdir(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	a, err := ProjectStateDir(filepath.Join(root, "state"), first)
	if err != nil {
		t.Fatal(err)
	}
	b, err := ProjectStateDir(filepath.Join(root, "state"), second)
	if err != nil || a == b {
		t.Fatal(a, b, err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(first, alias); err != nil {
		t.Skip(err)
	}
	linked, err := ProjectStateDir(filepath.Join(root, "state"), alias)
	if err != nil || linked != a {
		t.Fatal(linked, a, err)
	}
}

func TestCanonicalProjectDoesNotRedirectRuntimeState(t *testing.T) {
	root := t.TempDir()
	request := app.LaunchRequest{Directory: root, StateDir: filepath.Join(root, "state")}
	selected, err := CanonicalProject(request)
	if err != nil || selected.StateDir != request.StateDir || selected.Directory != root {
		t.Fatal(selected, err)
	}
}

func TestExplicitClientNeverStartsProjectNode(t *testing.T) {
	request := app.LaunchRequest{Command: "bee", Directory: t.TempDir(), StateDir: t.TempDir()}
	client := Client{Command: "bee", Mode: hive.Control, AttachOnly: true, Stdin: os.Stdin, Stdout: io.Discard}
	err := client.Run(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "No running Bee for this project") {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(request.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatal("display-only launch created state", entries)
	}
}

// SPDX-License-Identifier: MIT
package config

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRootManyWorkspacesShareRuntimeState(t *testing.T) {
	store, err := New(filepath.Join(t.TempDir(), "machine"))
	if err != nil {
		t.Fatal(err)
	}
	runtimeState := filepath.Join(t.TempDir(), "runtime")
	got, err := store.Update(context.Background(), 0, func(doc Document) (Document, error) {
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "workspace-a", ProjectDir: filepath.Join(runtimeState, "project-a"), RuntimeStateDir: runtimeState},
			{WorkspaceID: "workspace-b", ProjectDir: filepath.Join(runtimeState, "project-b"), RuntimeStateDir: runtimeState},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatalf("two workspace owners in one runtime: %v", err)
	}
	if len(got.Workspaces) != 2 {
		t.Fatal("lost workspace")
	}
	if _, err := os.Stat(runtimeState); !os.IsNotExist(err) {
		t.Fatal("configuration must not create runtime storage", err)
	}
}

func TestRootInvalidUTF8IsRefused(t *testing.T) {
	raw := []byte(`{"version":1,"revision":1,"enrollment_ref":"x`)
	raw = append(raw, 0xff)
	raw = append(raw, []byte(`","workspaces":[]}`)...)
	if _, err := Decode(raw); err == nil {
		t.Fatal("invalid UTF-8 silently rewritten")
	}
}

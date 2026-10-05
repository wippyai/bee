// SPDX-License-Identifier: MIT

package launch

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func makeProject(t *testing.T) string {
	t.Helper()
	project := filepath.Join(t.TempDir(), "project")
	if err := os.Mkdir(project, 0o700); err != nil {
		t.Fatal(err)
	}
	return project
}

func TestProjectStateDirUsesCanonicalDirectory(t *testing.T) {
	project := makeProject(t)
	alias := filepath.Join(filepath.Dir(project), "alias")
	if err := os.Symlink(project, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	root := filepath.Join(t.TempDir(), "state")
	first, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	linked, err := ProjectStateDir(root, alias)
	if err != nil {
		t.Fatal(err)
	}
	if linked != first {
		t.Fatalf("symlink state = %q, canonical state = %q", linked, first)
	}
}

func TestDefaultProjectStateDirAbsentReceiptIsReadOnly(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := makeProject(t)
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DefaultProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("state = %q, want %q", got, want)
	}
	if _, err := os.Lstat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("selection created root: %v", err)
	}
}

func TestDefaultProjectStateDirReceiptMatchKeepsLegacyRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	project := makeProject(t)
	canonical, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatal(err)
	}
	receipt := legacyProjectSelection{Version: 1, Mode: "legacy-root", ProjectDir: canonical, StateDir: root}
	writeReceipt(t, root, receipt)
	before := readDirectory(t, root)
	got, err := DefaultProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	if got != root {
		t.Fatalf("state = %q, want legacy root %q", got, root)
	}
	if after := readDirectory(t, root); !sameNames(before, after) {
		t.Fatalf("planning changed receipt directory: before=%v after=%v", before, after)
	}
}

func TestDefaultProjectStateDirReceiptNonmatchUsesHash(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	project := makeProject(t)
	other := makeProject(t)
	receipt := legacyProjectSelection{Version: 1, Mode: "legacy-root", ProjectDir: other, StateDir: root}
	writeReceipt(t, root, receipt)
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DefaultProjectStateDir(root, project)
	if err != nil || got != want {
		t.Fatalf("state = %q, want %q (err=%v)", got, want, err)
	}
}

func TestDefaultProjectStateDirRejectsMalformedReceipt(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	project := makeProject(t)
	if err := os.WriteFile(filepath.Join(root, legacyProjectFile), []byte(`{"version":1,"mode":"legacy-root","project_dir":"/tmp/project","state_dir":"/tmp/state","extra":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := DefaultProjectStateDir(root, project); err == nil || !strings.Contains(err.Error(), "invalid project state receipt") {
		t.Fatalf("malformed receipt error = %v", err)
	}
}

func TestDefaultProjectStateDirDoesNotWriteExistingReceipt(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	project := makeProject(t)
	receipt := legacyProjectSelection{Version: 1, Mode: "legacy-root", ProjectDir: project, StateDir: root}
	writeReceipt(t, root, receipt)
	before, err := os.ReadFile(filepath.Join(root, legacyProjectFile))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DefaultProjectStateDir(root, project); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(root, legacyProjectFile))
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatal("planning changed the compatibility receipt")
	}
}

func writeReceipt(t *testing.T, root string, receipt legacyProjectSelection) {
	t.Helper()
	data, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, legacyProjectFile), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func readDirectory(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func sameNames(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

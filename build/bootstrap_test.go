// SPDX-License-Identifier: MIT

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGitUsesSelectedCheckoutInsideParentHook(t *testing.T) {
	checkout := t.TempDir()
	t.Setenv("GIT_DIR", filepath.Join(t.TempDir(), "missing.git"))
	t.Setenv("GIT_WORK_TREE", t.TempDir())
	t.Setenv("GIT_INDEX_FILE", filepath.Join(t.TempDir(), "index"))
	if data, err := command(checkout, "git", "init", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("initialize isolated checkout: %v\n%s", err, data)
	}
	if _, err := os.Stat(filepath.Join(checkout, ".git")); err != nil {
		t.Fatal(err)
	}
	actual, err := output(checkout, "rev-parse", "--show-toplevel")
	if err != nil {
		t.Fatal(err)
	}
	checkout, err = filepath.EvalSymlinks(checkout)
	if err != nil {
		t.Fatal(err)
	}
	if actual != checkout {
		t.Fatalf("Git used %q, expected %q", actual, checkout)
	}
	for key, want := range map[string]string{"core.autocrlf": "false", "core.hooksPath": os.DevNull} {
		actual, err := output(checkout, "config", "--get", key)
		if err != nil || strings.TrimSpace(actual) != want {
			t.Fatalf("%s: got %q, %v", key, actual, err)
		}
	}
}

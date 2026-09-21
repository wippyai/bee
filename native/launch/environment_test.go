// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"os/exec"
	"path/filepath"
	"testing"

	envapi "github.com/wippyai/runtime/api/env"
)

func TestHostEnvironmentCapturesOnlyAbsoluteFacts(t *testing.T) {
	root := t.TempDir()
	storage, err := newHostEnvironment(hostResolver{
		lookPath:   func(string) (string, error) { return "", exec.ErrNotFound },
		homeDir:    func() (string, error) { return filepath.Join(root, "home"), nil },
		getwd:      func() (string, error) { return filepath.Join(root, "work"), nil },
		executable: func() (string, error) { return filepath.Join(root, "bin", "bee"), nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"home", "cwd", "self"} {
		if value, err := storage.Get(context.Background(), name); err != nil || !filepath.IsAbs(value) {
			t.Fatalf("%s = %q, %v", name, value, err)
		}
	}
	for _, name := range []string{"", ".", "..", "../bee", filepath.Join(root, "bee"), "foo..bar"} {
		if _, err := storage.Get(context.Background(), name); !errors.Is(err, envapi.ErrVariableNotFound) {
			t.Fatalf("Get(%q) error = %v", name, err)
		}
	}
}

func TestHostEnvironmentRejectsRelativeFacts(t *testing.T) {
	root := t.TempDir()
	resolver := hostResolver{
		lookPath:   func(string) (string, error) { return "", exec.ErrNotFound },
		homeDir:    func() (string, error) { return "relative", nil },
		getwd:      func() (string, error) { return filepath.Join(root, "work"), nil },
		executable: func() (string, error) { return filepath.Join(root, "bin", "bee"), nil },
	}
	if _, err := newHostEnvironment(resolver); err == nil {
		t.Fatal("relative home accepted")
	}
}

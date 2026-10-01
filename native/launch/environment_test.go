// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
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
		binary: func() binaryIdentityFacts {
			return binaryIdentityFacts{
				NativeModule: nativeModulePath, NativeVersion: "v1.2.3",
				NativeModules: `{"github.com/wippyai/bee/native":"v1.2.3"}`, RuntimeCommit: runtimeCommit,
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"home", "cwd", "self"} {
		if value, err := storage.Get(context.Background(), name); err != nil || !filepath.IsAbs(value) {
			t.Fatalf("%s = %q, %v", name, value, err)
		}
	}
	for name, expected := range map[string]string{
		"binary_native_module":  nativeModulePath,
		"binary_native_version": "v1.2.3",
		"binary_native_modules": `{"github.com/wippyai/bee/native":"v1.2.3"}`,
		"binary_runtime_commit": runtimeCommit,
	} {
		if value, err := storage.Get(context.Background(), name); err != nil || value != expected {
			t.Fatalf("%s = %q, %v; want %q", name, value, err, expected)
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

func TestHostEnvironmentExposesNamesWithoutValues(t *testing.T) {
	t.Setenv("BEE_LOGIN_METADATA_TEST", "fixture-sensitive-value")
	resolver := systemHostResolver()
	storage, err := newHostEnvironment(resolver)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := storage.Get(context.Background(), "environment_names")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "fixture-sensitive-value") {
		t.Fatal("environment metadata exposed a value")
	}
	var names []string
	if err := json.Unmarshal([]byte(raw), &names); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, name := range names {
		if name == "BEE_LOGIN_METADATA_TEST" {
			found = true
		}
	}
	if !found {
		t.Fatal("environment name missing")
	}
	if _, err := storage.Get(context.Background(), "BEE_LOGIN_METADATA_TEST"); !errors.Is(err, envapi.ErrVariableNotFound) {
		t.Fatal("host storage allowed raw environment access")
	}
}

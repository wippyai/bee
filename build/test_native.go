// SPDX-License-Identifier: MIT
// Run local native tests against the manifest's clean, patched runtime.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type nativeTestManifest struct {
	Runtime struct {
		Repository string   `json:"repository"`
		Commit     string   `json:"commit"`
		Go         string   `json:"go"`
		Tags       []string `json:"tags"`
		Patches    []struct {
			Path   string `json:"path"`
			SHA256 string `json:"sha256"`
		} `json:"patches"`
	} `json:"runtime"`
}

func nativeTestRun(dir string, env []string, name string, args ...string) error {
	command := exec.Command(name, args...)
	command.Dir, command.Env = dir, env
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%s failed: %w", name, err)
	}
	return nil
}

// Freeze verified patch bytes before starting external commands.
func nativeTestInputs(manifestPath, stage string) (nativeTestManifest, []string, error) {
	var manifest nativeTestManifest
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return manifest, nil, err
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, nil, err
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(manifest.Runtime.Commit) ||
		!regexp.MustCompile(`^1\.[0-9]+\.[0-9]+$`).MatchString(manifest.Runtime.Go) ||
		manifest.Runtime.Repository == "" || strings.HasPrefix(manifest.Runtime.Repository, "-") {
		return manifest, nil, fmt.Errorf("native test requires pinned runtime repository, commit and Go version")
	}
	var patches []string
	for i, patch := range manifest.Runtime.Patches {
		if !filepath.IsLocal(patch.Path) {
			return manifest, nil, fmt.Errorf("patch path must be manifest-local")
		}
		data, err := os.ReadFile(filepath.Join(filepath.Dir(manifestPath), patch.Path))
		if err != nil {
			return manifest, nil, err
		}
		if fmt.Sprintf("%x", sha256.Sum256(data)) != patch.SHA256 {
			return manifest, nil, fmt.Errorf("patch checksum mismatch: %s", patch.Path)
		}
		frozen := filepath.Join(stage, fmt.Sprintf("patch-%d", i))
		if err := os.WriteFile(frozen, data, 0600); err != nil {
			return manifest, nil, err
		}
		patches = append(patches, frozen)
	}
	return manifest, patches, nil
}

func testNative(manifestPath, module string) error {
	manifestPath, err := filepath.Abs(manifestPath)
	if err != nil {
		return err
	}
	module, err = filepath.Abs(module)
	if err != nil {
		return err
	}
	stage, err := os.MkdirTemp("", "bee-native-test-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	manifest, patches, err := nativeTestInputs(manifestPath, stage)
	if err != nil {
		return err
	}
	env := []string{}
	for _, variable := range os.Environ() {
		key, _, _ := strings.Cut(variable, "=")
		if key != "GOWORK" && key != "GOTOOLCHAIN" && key != "GOFLAGS" {
			env = append(env, variable)
		}
	}
	env = append(env, "GOWORK=off", "GOTOOLCHAIN=go"+manifest.Runtime.Go, "GOFLAGS=")
	source := filepath.Join(stage, "runtime")
	if err := nativeTestRun("", env, "git", "clone", "--no-checkout", "--filter=blob:none", manifest.Runtime.Repository, source); err != nil {
		return err
	}
	if err := nativeTestRun(source, env, "git", "checkout", "--detach", manifest.Runtime.Commit); err != nil {
		return err
	}
	for _, patch := range patches {
		if err := nativeTestRun(source, env, "git", "apply", "--check", patch); err != nil {
			return err
		}
		if err := nativeTestRun(source, env, "git", "apply", patch); err != nil {
			return err
		}
	}
	for _, extension := range []string{"mod", "sum"} {
		data, err := os.ReadFile(filepath.Join(module, "go."+extension))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(stage, "native."+extension), data, 0600); err != nil {
			return err
		}
	}
	modfile := "-modfile=" + filepath.Join(stage, "native.mod")
	if err := nativeTestRun(module, env, "go", "mod", "edit", modfile, "-replace=github.com/wippyai/runtime="+source); err != nil {
		return err
	}
	if err := nativeTestRun(module, env, "go", "test", modfile, "-mod=readonly", "-race", "-tags", strings.Join(manifest.Runtime.Tags, ","), "./..."); err != nil {
		return err
	}
	return nativeTestRun(module, env, "go", "vet", modfile, "-mod=readonly", "-tags", strings.Join(manifest.Runtime.Tags, ","), "./...")
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: test_native MANIFEST NATIVE_MODULE")
		os.Exit(2)
	}
	if err := testNative(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

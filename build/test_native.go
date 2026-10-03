// SPDX-License-Identifier: MIT
// Run native tests against the manifest's exact unpatched module dependency.
package main

import (
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
		Repository string            `json:"repository"`
		Commit     string            `json:"commit"`
		Go         string            `json:"go"`
		Tags       []string          `json:"tags"`
		Patches    []json.RawMessage `json:"patches"`
	} `json:"runtime"`
}

type runtimeModule struct {
	Version string
	Replace *runtimeModule
}

func nativeTestInputs(manifestPath string) (nativeTestManifest, error) {
	var manifest nativeTestManifest
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return manifest, err
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, err
	}
	if manifest.Runtime.Repository != "https://github.com/wippyai/runtime.git" ||
		!regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(manifest.Runtime.Commit) ||
		!regexp.MustCompile(`^1\.[0-9]+\.[0-9]+$`).MatchString(manifest.Runtime.Go) || len(manifest.Runtime.Patches) != 0 {
		return manifest, fmt.Errorf("native tests require an exact unpatched upstream runtime")
	}
	return manifest, nil
}

func verifyRuntimeModule(manifest nativeTestManifest, module runtimeModule) error {
	if module.Replace != nil || !strings.HasSuffix(module.Version, "-"+manifest.Runtime.Commit[:12]) {
		return fmt.Errorf("native runtime %s does not match manifest commit %s without replacements", module.Version, manifest.Runtime.Commit)
	}
	return nil
}

func testNative(manifestPath, module string) error {
	manifest, err := nativeTestInputs(manifestPath)
	if err != nil {
		return err
	}
	module, err = filepath.Abs(module)
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
	command := exec.Command("go", "list", "-mod=readonly", "-m", "-json", "github.com/wippyai/runtime")
	command.Dir, command.Env = module, env
	data, err := command.Output()
	if err != nil {
		return err
	}
	var dependency runtimeModule
	if err := json.Unmarshal(data, &dependency); err != nil {
		return err
	}
	if err := verifyRuntimeModule(manifest, dependency); err != nil {
		return err
	}
	for _, operation := range []string{"test", "vet"} {
		args := []string{operation, "-mod=readonly", "-tags", strings.Join(manifest.Runtime.Tags, ","), "./..."}
		if operation == "test" {
			args = append([]string{"test", "-race"}, args[1:]...)
		}
		command := exec.Command("go", args...)
		command.Dir, command.Env, command.Stdout, command.Stderr = module, env, os.Stdout, os.Stderr
		if err := command.Run(); err != nil {
			return fmt.Errorf("go %s: %w", operation, err)
		}
	}
	return nil
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

// SPDX-License-Identifier: MIT
// Verify read-only preview of a public, uninstalled Hub package resource.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const defaultRuntime = ".wippy/bin/bee-wippy"

var success = regexp.MustCompile(`HUB_PREVIEW_PASS digest=([0-9a-f]{64})`)

// This acceptance reaches a public package using an empty HOME, so it cannot
// use an ambient token or leave an artifact in a developer's vendor cache.
func runCommand(ctx context.Context, directory, runtime string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process != nil && command.Process.Pid > 0 {
			return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	command.WaitDelay = 3 * time.Second
	command.Env = []string{
		"HOME=" + filepath.Join(directory, "home"),
		"XDG_CONFIG_HOME=" + filepath.Join(directory, "config"),
		"XDG_DATA_HOME=" + filepath.Join(directory, "data"),
		"XDG_STATE_HOME=" + filepath.Join(directory, "state"),
		"PATH=/usr/bin:/bin",
		"GOMAXPROCS=2",
	}
	return command.CombinedOutput()
}

func copyFixture(root string) error {
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join("tests", "fixtures", "hub_preview"))); err != nil {
		return fmt.Errorf("copy Hub preview fixture: %w", err)
	}
	for _, module := range []string{"hub", "persist", "sync", "threads"} {
		if err := os.CopyFS(filepath.Join(root, "modules", module), os.DirFS(filepath.Join("modules", module))); err != nil {
			return fmt.Errorf("stage Hub component dependency %s: %w", module, err)
		}
	}
	lock := "directories:\n  modules: .wippy\n  src: ./src\nmodules:\n- name: bee/hub\n  version: 0.1.0-dev\n- name: bee/persist\n  version: 0.1.0-dev\n- name: bee/sync\n  version: 0.1.0-dev\n- name: bee/threads\n  version: 0.1.0-dev\n"
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte(lock), 0600); err != nil {
		return fmt.Errorf("write fixture lock: %w", err)
	}
	config := "version: '1.0'\nregistry:\n  enable_history: true\n  history_type: sqlite\n  history_path: registry.db\nshutdown:\n  timeout: 2s\nworkspace:\n  replacements:\n    bee/hub: ./modules/hub\n    bee/persist: ./modules/persist\n    bee/sync: ./modules/sync\n    bee/threads: ./modules/threads\n"
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte(config), 0600); err != nil {
		return fmt.Errorf("write fixture configuration: %w", err)
	}
	return nil
}

func main() {
	runtimeFlag := flag.String("runtime", defaultRuntime, "Wippy runtime to verify")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "resolve runtime:", err)
		os.Exit(1)
	}
	if info, statErr := os.Stat(runtime); statErr != nil || info.IsDir() {
		fmt.Fprintf(os.Stderr, "candidate runtime %q is unavailable\n", runtime)
		os.Exit(1)
	}
	root, err := os.MkdirTemp("", "bee-hub-preview-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "create disposable Hub preview fixture:", err)
		os.Exit(1)
	}
	defer os.RemoveAll(root)
	if err := copyFixture(root); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	lint, lintErr := runCommand(ctx, root, runtime, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	cancel()
	if lintErr != nil {
		fmt.Fprintf(os.Stderr, "strict Hub preview fixture lint failed: %v\n%s", lintErr, lint)
		os.Exit(1)
	}
	ctx, cancel = context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	output, runErr := runCommand(ctx, root, runtime, "run", "--verbose", "--host", "bee.hub.preview.probe:workers", "--", "hub-preview-probe")
	if runErr != nil {
		fmt.Fprintf(os.Stderr, "Hub preview probe failed: %v\n%s", runErr, output)
		os.Exit(1)
	}
	match := success.FindStringSubmatch(string(output))
	if len(match) != 2 {
		fmt.Fprintf(os.Stderr, "Hub preview probe exited cleanly without a measured-artifact marker\n%s", output)
		os.Exit(1)
	}
	fmt.Println("HUB_PREVIEW_PASS digest=" + match[1])
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "HUB_PREVIEW_") {
			fmt.Println(line)
		}
	}
}

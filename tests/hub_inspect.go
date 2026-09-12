// SPDX-License-Identifier: MIT
// Run the narrow live Hub inspection acceptance against a public artifact.
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

var success = regexp.MustCompile(`HUB_INSPECT_PASS digest=([0-9a-f]{64})`)

// runCommand bounds the runtime and any workers it starts. This fixture reaches
// the public Hub, so cleanup cannot depend on a well-behaved failed request.
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
	// A fresh HOME prevents an ambient Hub login or provider credential from
	// participating in this public-package acceptance.
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
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join("tests", "fixtures", "hub_inspect"))); err != nil {
		return fmt.Errorf("copy Hub inspection fixture: %w", err)
	}
	if err := os.CopyFS(filepath.Join(root, "src", "hub"), os.DirFS(filepath.Join("src", "hub"))); err != nil {
		return fmt.Errorf("copy production Hub source: %w", err)
	}
	bounds, err := os.ReadFile(filepath.Join("src", "threads", "records", "bounds.lua"))
	if err != nil {
		return fmt.Errorf("read production bounds: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "records", "bounds.lua"), bounds, 0600); err != nil {
		return fmt.Errorf("copy production bounds: %w", err)
	}
	for _, name := range []string{"bounds.lua", "canonical.lua"} {
		contents, readErr := os.ReadFile(filepath.Join("src", "sync", name))
		if readErr != nil {
			return fmt.Errorf("read production sync %s: %w", name, readErr)
		}
		if writeErr := os.WriteFile(filepath.Join(root, "src", "sync", name), contents, 0600); writeErr != nil {
			return fmt.Errorf("copy production sync %s: %w", name, writeErr)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write fixture lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return fmt.Errorf("write fixture configuration: %w", err)
	}
	return nil
}

func strictLint(runtime, root string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	output, err := runCommand(ctx, root, runtime, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict Hub fixture lint failed: %w\n%s", err, output)
	}
	return nil
}

func run(runtime string) error {
	root, err := os.MkdirTemp("", "bee-hub-inspect-")
	if err != nil {
		return fmt.Errorf("create disposable Hub fixture: %w", err)
	}
	defer os.RemoveAll(root)
	if err := copyFixture(root); err != nil {
		return err
	}
	if err := strictLint(runtime, root); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	output, err := runCommand(ctx, root, runtime, "run", "--verbose", "--host", "bee.hub_inspect_probe:workers", "--", "hub-inspect-probe")
	if err != nil {
		return fmt.Errorf("Hub inspection probe failed: %w\n%s", err, output)
	}
	match := success.FindStringSubmatch(string(output))
	if len(match) != 2 {
		return fmt.Errorf("Hub inspection probe exited cleanly without a measured-artifact marker\n%s", output)
	}
	fmt.Println("HUB_INSPECT_PASS digest=" + match[1])
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
	if err := run(runtime); err != nil {
		fmt.Fprintln(os.Stderr, strings.TrimSpace(err.Error()))
		os.Exit(1)
	}
}

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

func copyFixture(root string, manage bool) error {
	fixture := "hub_inspect"
	if manage {
		fixture = "hub_manage"
	}
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join("tests", "fixtures", fixture))); err != nil {
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
	if err := os.MkdirAll(filepath.Join(root, "src", "persist"), 0700); err != nil {
		return err
	}
	transaction, err := os.ReadFile(filepath.Join("modules", "bee-persist", "src", "transaction.lua"))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "src", "persist", "transaction.lua"), transaction, 0600); err != nil {
		return err
	}
	manifest := "version: '1.0'\nnamespace: bee.persist\nentries:\n- name: transaction\n  kind: library.lua\n  source: file://transaction.lua\n  modules: [sql, time]\n"
	if err := os.WriteFile(filepath.Join(root, "src", "persist", "_index.yaml"), []byte(manifest), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write fixture lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nregistry:\n  enable_history: true\n  history_type: sqlite\n  history_path: registry.db\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
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

func run(runtime string, manage bool) error {
	root, err := os.MkdirTemp("", "bee-hub-inspect-")
	if err != nil {
		return fmt.Errorf("create disposable Hub fixture: %w", err)
	}
	defer os.RemoveAll(root)
	if err := copyFixture(root, manage); err != nil {
		return err
	}
	if err := strictLint(runtime, root); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	host, command := "bee.hub_inspect_probe:workers", "hub-inspect-probe"
	if manage {
		host, command = "bee:workers", "hub-manage-probe"
		for _, check := range []struct {
			command string
			marker  string
		}{
			{command: "hub-manage-narrow", marker: "HUB_MANAGE_NARROW_PASS"},
			{command: "hub-manage-reader", marker: "HUB_MANAGE_READER_PASS"},
		} {
			checked, checkErr := runCommand(ctx, root, runtime, "run", "--verbose", "--host", host, "--", check.command)
			if checkErr != nil || !strings.Contains(string(checked), check.marker) {
				return fmt.Errorf("Hub authority check %s failed: %v\n%s", check.command, checkErr, checked)
			}
		}
	}
	output, err := runCommand(ctx, root, runtime, "run", "--verbose", "--host", host, "--", command)
	if err != nil {
		return fmt.Errorf("Hub inspection probe failed: %w\n%s", err, output)
	}
	if manage {
		if !strings.Contains(string(output), "HUB_MANAGE_PASS") {
			return fmt.Errorf("no management acceptance marker\n%s", output)
		}
		restarted, restartErr := runCommand(ctx, root, runtime, "run", "--verbose", "--host", host, "--", "hub-manage-restart")
		if restartErr != nil || !strings.Contains(string(restarted), "HUB_MANAGE_RESTART_PASS") {
			return fmt.Errorf("management restart failed: %v\n%s", restartErr, restarted)
		}
		fmt.Println("HUB_MANAGE_PASS HUB_MANAGE_RESTART_PASS")
		return nil
	}
	match := success.FindStringSubmatch(string(output))
	if len(match) != 2 {
		return fmt.Errorf("Hub inspection probe exited cleanly without a measured-artifact marker\n%s", output)
	}
	fmt.Println("HUB_INSPECT_PASS digest=" + match[1])
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, "HUB_PREVIEW_") {
			fmt.Println(line)
		}
	}
	return nil
}

func main() {
	runtimeFlag := flag.String("runtime", defaultRuntime, "Wippy runtime to verify")
	manage := flag.Bool("manage", false, "exercise confirmed installation, update, removal and restart")
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
	if err := run(runtime, *manage); err != nil {
		fmt.Fprintln(os.Stderr, strings.TrimSpace(err.Error()))
		os.Exit(1)
	}
}

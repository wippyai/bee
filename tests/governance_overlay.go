// SPDX-License-Identifier: MIT
// Run the isolated native registry overlay ownership and composed-base gates.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const defaultRuntime = ".wippy/bin/bee-wippy"

const (
	ownerGate    = "owner"
	composedGate = "composed-base"
)

// runCommand bounds both the runtime and any descendants it starts. The
// disposable fixture must not leave a worker behind after a timeout.
func runCommand(ctx context.Context, directory string, environment []string, runtime string, args ...string) ([]byte, error) {
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
	command.Env = commandEnvironment(environment)
	output, err := command.CombinedOutput()
	if command.Process != nil && command.Process.Pid > 0 {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	return output, err
}

func commandEnvironment(overrides []string) []string {
	replaced := make(map[string]struct{}, len(overrides))
	for _, value := range overrides {
		if key, _, ok := strings.Cut(value, "="); ok {
			replaced[key] = struct{}{}
		}
	}
	environment := make([]string, 0, len(os.Environ())+len(overrides))
	for _, value := range os.Environ() {
		key, _, ok := strings.Cut(value, "=")
		if !ok {
			continue
		}
		if _, replace := replaced[key]; !replace {
			environment = append(environment, value)
		}
	}
	return append(environment, overrides...)
}

func copyFixture(root, fixture string) error {
	destination := filepath.Join(root, "src")
	if err := os.CopyFS(destination, os.DirFS(fixture)); err != nil {
		return fmt.Errorf("copy %s fixture: %w", fixture, err)
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write fixture lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return fmt.Errorf("write fixture config: %w", err)
	}
	return nil
}

func disposableEnvironment(root string) []string {
	home := filepath.Join(root, "home")
	config := filepath.Join(root, "config")
	data := filepath.Join(root, "data")
	return []string{
		"HOME=" + home,
		"XDG_CONFIG_HOME=" + config,
		"XDG_DATA_HOME=" + data,
		"GOMAXPROCS=2",
	}
}

func strictLint(runtime, root string, environment []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	output, err := runCommand(ctx, root, environment, runtime, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict fixture lint failed: %w\n%s", err, output)
	}
	return nil
}

func runProbe(runtime, root, commandName string, environment []string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return runCommand(ctx, root, environment, runtime, "run", "--verbose", "--host", "bee.governance_overlay_probe:workers", "--", commandName)
}

func runComposedProbe(runtime, root string, environment []string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return runCommand(ctx, root, environment, runtime, "run", "--verbose", "--host", "bee.governance_overlay_composed_probe:workers", "--", "governance-overlay-composed-probe")
}

func linesWithMarker(output []byte, marker string) string {
	var lines []string
	for _, line := range strings.Split(string(output), "\n") {
		if strings.Contains(line, marker) {
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "\n")
}

func runOwner(runtime string) error {
	root, err := os.MkdirTemp("", "bee-governance-overlay-owner-")
	if err != nil {
		return fmt.Errorf("create disposable owner root: %w", err)
	}
	defer os.RemoveAll(root)
	if err := copyFixture(root, filepath.Join("tests", "fixtures", "governance_overlay")); err != nil {
		return err
	}
	environment := disposableEnvironment(root)
	if err := strictLint(runtime, root, environment); err != nil {
		return err
	}
	output, err := runProbe(runtime, root, "governance-overlay-probe", environment)
	if err != nil {
		return fmt.Errorf("owner overlay probe failed: %w\n%s", err, output)
	}
	if marker := linesWithMarker(output, "GOVERNANCE_OVERLAY_OWNER_PASS"); marker == "" {
		return fmt.Errorf("owner overlay probe exited cleanly without success marker\n%s", output)
	} else {
		fmt.Println(marker)
	}
	return nil
}

func runComposedBase(runtime string) error {
	root, err := os.MkdirTemp("", "bee-governance-overlay-composed-")
	if err != nil {
		return fmt.Errorf("create disposable composed-base root: %w", err)
	}
	defer os.RemoveAll(root)
	if err := copyFixture(root, filepath.Join("tests", "fixtures", "governance_overlay_composed")); err != nil {
		return err
	}
	environment := disposableEnvironment(root)
	if err := strictLint(runtime, root, environment); err != nil {
		return err
	}
	output, err := runComposedProbe(runtime, root, environment)
	if stale := linesWithMarker(output, "GOVERNANCE_COMPOSED_BASE_STALE_ACCEPTED"); stale != "" {
		// This marker is emitted only after the probe has read the effective
		// state and confirmed that the reviewed value was committed alongside
		// the intervening dependency. A crash without it is a separate failure.
		fmt.Println(stale)
		return fmt.Errorf("composed-base gate missing atomic refusal: runtime accepted reviewed overlay after dependency change")
	}
	if err != nil {
		return fmt.Errorf("composed-base probe failed before refusal or stale-acceptance marker (unrelated runtime failure): %w\n%s", err, output)
	}
	if refused := linesWithMarker(output, "GOVERNANCE_COMPOSED_BASE_REFUSED"); refused != "" {
		fmt.Println(refused)
		return nil
	}
	return fmt.Errorf("composed-base probe exited cleanly without refusal marker\n%s", output)
}

func run() error {
	runtimeFlag := flag.String("runtime", defaultRuntime, "Wippy runtime to verify")
	gate := flag.String("gate", ownerGate, "gate to run: owner or composed-base")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return fmt.Errorf("resolve runtime: %w", err)
	}
	if info, err := os.Stat(runtime); err != nil || info.IsDir() {
		return fmt.Errorf("candidate runtime %q is unavailable", runtime)
	}
	switch *gate {
	case ownerGate:
		return runOwner(runtime)
	case composedGate:
		return runComposedBase(runtime)
	default:
		return fmt.Errorf("unknown gate %q", *gate)
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// SPDX-License-Identifier: MIT
// Acceptance test proving two actual bee.host:main actors with independent
// workspace SQLite database resources inside ONE runtime without cross-routing.
// Explicit Linux acceptance; relies on process group isolation and POSIX signals.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// runCommand runs an external command bounded by a context timeout.
// It assigns a distinct process group to prevent orphaned background descendants,
// registers a Cancel hook to SIGKILL the entire process group upon timeout,
// and enforces WaitDelay to avoid hanging on lingering open stdout/stderr pipes.
func runCommand(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.WaitDelay = 3 * time.Second
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}

	out, err := cmd.CombinedOutput()
	if cmd.Process != nil && cmd.Process.Pid > 0 {
		// Stop any remaining members of the owned process group. CombinedOutput
		// has already waited for the direct child; grandchildren are not ours to reap.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	return out, err
}

// runSupervisor deduplicates supervisor execution between source and packed modes.
// Output is kept quiet on success and preserved in detail on failure.
func runSupervisor(runtime string, dir string, env []string, desc string, budget time.Duration, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()

	out, err := runCommand(ctx, dir, env, runtime, args...)
	outStr := string(out)
	if err != nil {
		return fmt.Errorf("%s failed: %w\nOutput:\n%s", desc, err, outStr)
	}
	if !strings.Contains(outStr, "ACCEPTANCE VERIFIED") {
		return fmt.Errorf("%s finished without verification marker\nOutput:\n%s", desc, outStr)
	}
	fmt.Printf("%s passed cleanly.\n", desc)
	return nil
}

// Each source/pack boot owns all subsystem stores inside its disposable root.
func databaseEnvironment(root string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	environment := make([]string, 0, len(names))
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	return environment
}

func run() error {
	runtimePath := ".wippy/bin/wippy"
	if len(os.Args) > 1 {
		runtimePath = os.Args[1]
	}
	runtime, err := filepath.Abs(runtimePath)
	if err != nil {
		return fmt.Errorf("resolve runtime path: %w", err)
	}

	delayed := len(os.Args) > 2 && os.Args[2] == "--delayed"
	command, budget := "workspace-hosts-supervisor", 35*time.Second
	if delayed {
		command, budget = "workspace-hosts-delayed-supervisor", 45*time.Second
	}
	root, err := os.MkdirTemp("", "bee-workspace-hosts-")
	if err != nil {
		return fmt.Errorf("create temp root: %w", err)
	}
	defer os.RemoveAll(root)

	// Copy production src/
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS("src")); err != nil {
		return fmt.Errorf("copy src: %w", err)
	}

	// This host-authority fixture exercises singleton thread fencing. Production
	// Settings allows independent display instances; select singleton explicitly
	// only in this disposable composition to preserve the generic fencing proof.
	settingsManifest := filepath.Join(root, "src", "apps", "settings", "_index.yaml")
	settingsData, err := os.ReadFile(settingsManifest)
	if err != nil {
		return fmt.Errorf("read fixture Settings policy: %w", err)
	}
	if strings.Count(string(settingsData), "instance_policy: multiple") != 1 {
		return fmt.Errorf("unexpected production Settings instance policy")
	}
	settingsData = []byte(strings.Replace(string(settingsData), "instance_policy: multiple", "instance_policy: singleton", 1))
	if err := os.WriteFile(settingsManifest, settingsData, 0600); err != nil {
		return fmt.Errorf("select fixture singleton policy: %w", err)
	}

	// Copy fixture into src/workspace_hosts
	if err := os.CopyFS(filepath.Join(root, "src", "workspace_hosts"), os.DirFS("tests/fixtures/workspace_hosts")); err != nil {
		return fmt.Errorf("copy fixture: %w", err)
	}
	if delayed {
		// Replace only the disposable composition's broker to deliver a reply
		// after the production host's unchanged 30-second caller deadline.
		broker, err := os.ReadFile("tests/fixtures/workspace_hosts/delayed_broker.lua")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(root, "src", "core", "applications", "broker.lua"), broker, 0600); err != nil {
			return err
		}
	}

	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write wippy.lock: %w", err)
	}
	manifest, manifestErr := os.ReadFile("wippy.yaml")
	if manifestErr != nil {
		return fmt.Errorf("read wippy.yaml: %w", manifestErr)
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.yaml"), manifest, 0600); err != nil {
		return fmt.Errorf("write wippy.yaml: %w", err)
	}

	// Step 1: Strict Lua lint
	fmt.Println("=== Step 1: Strict Lua Lint ===")
	lintCtx, lintCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer lintCancel()

	lintOut, err := runCommand(lintCtx, root, nil, runtime, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict Lua lint failed: %w\nOutput:\n%s", err, string(lintOut))
	}
	fmt.Println("Lint passed cleanly.")

	// Step 2: Source execution of bounded acceptance test
	fmt.Println("=== Step 2: Dual Workspace Hosts Source Acceptance ===")
	sourceEnv := databaseEnvironment(root)
	if err := runSupervisor(runtime, root, sourceEnv, "Source acceptance", budget, "run", "--verbose", "--host", "bee:workers", "--", command); err != nil {
		return err
	}

	// Step 3: Pack execution
	fmt.Println("=== Step 3: Pack Execution Check ===")
	packFile := filepath.Join(root, "bee.wapp")
	packBuildCtx, packBuildCancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer packBuildCancel()

	packOut, err := runCommand(packBuildCtx, root, nil, runtime, "pack", packFile)
	if err != nil {
		return fmt.Errorf("pack build failed: %w\nOutput:\n%s", err, string(packOut))
	}
	fmt.Printf("Pack build succeeded: %s\n", packFile)

	packedDir := filepath.Join(root, "packed")
	if err := os.Mkdir(packedDir, 0700); err != nil {
		return fmt.Errorf("create packed dir: %w", err)
	}

	packEnv := databaseEnvironment(packedDir)
	if err := runSupervisor(runtime, packedDir, packEnv, "Pack acceptance", budget, "run", packFile, "--verbose", "--host", "bee:workers", "--", command); err != nil {
		return err
	}

	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
}

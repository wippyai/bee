// SPDX-License-Identifier: MIT
// Acceptance harness for real native-window hook delivery.
// Owns staging of disposable fixture composition, isolated database environments,
// and execution on the terminal host.
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	defaultRuntime = ".wippy/bin/bee-wippy"
	markerSuccess  = "BEE_WINDOW_HOOKS_ACCEPTANCE: OK"
)

func copyDir(dst, src string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode())
	})
}

func copyFile(dst, src string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

func pickRandomLoopbackAddress() (string, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	defer listener.Close()
	return listener.Addr().String(), nil
}

func stageComposition(tempDir, srcDir, repoRoot string) (string, error) {
	// 1. Copy src tree from target srcDir
	if err := copyDir(filepath.Join(tempDir, "src"), filepath.Join(srcDir, "src")); err != nil {
		return "", fmt.Errorf("copy src from %s: %w", srcDir, err)
	}
	if err := copyDir(filepath.Join(tempDir, "modules"), filepath.Join(repoRoot, "modules")); err != nil {
		return "", fmt.Errorf("copy component modules: %w", err)
	}

	// 2. Copy managed gateway HTTP definitions into src/managed
	gatewayManaged := filepath.Join(repoRoot, "tests", "fixtures", "modules", "gateway", "src", "managed")
	if err := copyDir(filepath.Join(tempDir, "src", "managed"), gatewayManaged); err != nil {
		return "", fmt.Errorf("copy gateway managed definitions: %w", err)
	}

	// 3. Copy window_hooks fixture into src/tests/window_hooks
	windowHooksFixture := filepath.Join(repoRoot, "tests", "fixtures", "window_hooks")
	if err := copyDir(filepath.Join(tempDir, "src", "tests", "window_hooks"), windowHooksFixture); err != nil {
		return "", fmt.Errorf("copy window_hooks fixture: %w", err)
	}
	// Inject latency only in this disposable gateway method. It still calls
	// the real owner, so terminal input must progress while the call is pending.
	if err := copyFile(filepath.Join(tempDir, "modules", "gateway", "src", "binding", "hook_claim_method.lua"), filepath.Join(windowHooksFixture, "claim.lua")); err != nil {
		return "", err
	}
	gatewayIndex := filepath.Join(tempDir, "modules", "gateway", "src", "binding", "_index.yaml")
	gatewayBytes, err := os.ReadFile(gatewayIndex)
	if err != nil {
		return "", err
	}
	claimAnchor := "source: file://hook_claim_method.lua\n  method: handle\n"
	if strings.Count(string(gatewayBytes), claimAnchor) != 1 {
		return "", fmt.Errorf("missing fixture claim method declaration")
	}
	if err := os.WriteFile(gatewayIndex, []byte(strings.Replace(string(gatewayBytes), claimAnchor, claimAnchor+"  modules: [time]\n", 1)), 0600); err != nil {
		return "", err
	}

	// 4. Copy runtime config files
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		srcFile := filepath.Join(repoRoot, name)
		if err := copyFile(filepath.Join(tempDir, name), srcFile); err != nil {
			return "", fmt.Errorf("copy %s: %w", name, err)
		}
	}

	// 5. Pick ephemeral random loopback address for gateway
	endpointAddress, err := pickRandomLoopbackAddress()
	if err != nil {
		return "", fmt.Errorf("pick random loopback port: %w", err)
	}

	// Patch the owning indexes in the disposable fixture, with exact anchors.
	patches := []struct{ path, from, to string }{
		{"src/_index.yaml", "address: 127.0.0.1:0", "address: " + endpointAddress},
		{"modules/gateway/src/security/_index.yaml", `resource matches "^http://127\\.0\\.0\\.1:[0-9]+/ready$"`, `resource == "http://` + endpointAddress + `/ready"`},
		{"src/_index.yaml", "    - bee.driver.grok:binding\n", "    - bee.driver.grok:binding\n    - bee.window_hooks_fixture:binding\n"},
		{"src/_index.yaml", "hide_logs: true", "hide_logs: false"},
	}
	for _, patch := range patches {
		path := filepath.Join(tempDir, filepath.FromSlash(patch.path))
		data, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		if strings.Count(string(data), patch.from) != 1 {
			return "", fmt.Errorf("expected one anchor %q in %s", patch.from, patch.path)
		}
		if err := os.WriteFile(path, []byte(strings.Replace(string(data), patch.from, patch.to, 1)), 0644); err != nil {
			return "", err
		}
	}

	compositionFile := filepath.Join(tempDir, "src", "deps", "_index.yaml")
	gatewayBytes, err = os.ReadFile(compositionFile)
	if err != nil {
		return "", err
	}
	const selectedListener = "- name: target_listener\n    value: bee:gateway_listener"
	if strings.Count(string(gatewayBytes), selectedListener) != 1 {
		return "", fmt.Errorf("missing root gateway listener target")
	}
	gatewayContent := strings.Replace(string(gatewayBytes), selectedListener, "- name: target_listener\n    value: bee.managed:listener", 1)
	if err := os.WriteFile(compositionFile, []byte(gatewayContent), 0644); err != nil {
		return "", err
	}

	// 7. Patch src/managed/_index.yaml with checked anchor
	managedFile := filepath.Join(tempDir, "src", "managed", "_index.yaml")
	managedBytes, err := os.ReadFile(managedFile)
	if err != nil {
		return "", fmt.Errorf("read managed/_index.yaml: %w", err)
	}
	managedContent := string(managedBytes)
	listenerAnchor := "addr: 127.0.0.1:18790"
	if !strings.Contains(managedContent, listenerAnchor) {
		return "", fmt.Errorf("missing anchor %q in managed/_index.yaml", listenerAnchor)
	}
	managedContent = strings.Replace(managedContent, listenerAnchor, "addr: "+endpointAddress, 1)
	if err := os.WriteFile(managedFile, []byte(managedContent), 0644); err != nil {
		return "", fmt.Errorf("write managed/_index.yaml: %w", err)
	}

	// 8. Create isolated config / home dirs
	for _, dir := range []string{"home", "config", "data", "state"} {
		if err := os.MkdirAll(filepath.Join(tempDir, dir), 0755); err != nil {
			return "", err
		}
	}

	return endpointAddress, nil
}

func isolatedEnvironment(tempDir string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	env := os.Environ()
	for _, name := range names {
		env = append(env, fmt.Sprintf("BEE_%s_DB=%s", strings.ToUpper(name), filepath.Join(tempDir, name+".db")))
	}
	env = append(env,
		"XDG_CONFIG_HOME="+filepath.Join(tempDir, "config"),
		"XDG_DATA_HOME="+filepath.Join(tempDir, "data"),
		"XDG_STATE_HOME="+filepath.Join(tempDir, "state"),
		"HOME="+filepath.Join(tempDir, "home"),
	)
	return env
}

func runHarness() error {
	runtimeFlag := flag.String("runtime", defaultRuntime, "path to runtime executable")
	srcFlag := flag.String("src", "", "source directory to stage (defaults to repository root)")
	keepTemp := flag.Bool("keep-temp", false, "do not delete temporary directory after run")
	crash := flag.Bool("crash", false, "terminate the window actor before checkpoint restore")
	pendingHook := flag.Bool("pending-hook", false, "crash after an accepted hook before its first claim")
	cancelRecovery := flag.Bool("cancel-recovery", false, "close the recovery view before delayed admission finishes")
	beeFlag := flag.String("bee", "", "shipped Bee executable whose hook-post command submits the child's command hooks")
	flag.Parse()

	runtimePath, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return fmt.Errorf("resolve runtime path: %w", err)
	}
	if _, err := os.Stat(runtimePath); err != nil {
		return fmt.Errorf("runtime not found at %s: %w", runtimePath, err)
	}

	// Determine repository root
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	repoRoot, err := filepath.Abs(cwd)
	if err != nil {
		return err
	}

	srcDir := repoRoot
	if *srcFlag != "" {
		srcDir, err = filepath.Abs(*srcFlag)
		if err != nil {
			return fmt.Errorf("resolve src path: %w", err)
		}
	}

	tempDir, err := os.MkdirTemp("", "bee-window-live-hooks-")
	if err != nil {
		return fmt.Errorf("create temp directory: %w", err)
	}
	if !*keepTemp {
		defer os.RemoveAll(tempDir)
	} else {
		fmt.Printf("Keeping temporary staging directory: %s\n", tempDir)
	}

	endpoint, err := stageComposition(tempDir, srcDir, repoRoot)
	if err != nil {
		return fmt.Errorf("stage composition: %w", err)
	}

	env := isolatedEnvironment(tempDir)
	if *beeFlag != "" {
		if *crash || *pendingHook || *cancelRecovery {
			return fmt.Errorf("-bee runs the command-hook acceptance and takes no recovery mode")
		}
		beePath, err := filepath.Abs(*beeFlag)
		if err != nil {
			return fmt.Errorf("resolve Bee executable: %w", err)
		}
		if _, err := os.Stat(beePath); err != nil {
			return fmt.Errorf("Bee executable not found at %s: %w", beePath, err)
		}
		env = append(env, "BEE_WINDOW_HOOKS_COMMAND="+beePath)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	// 1. Run lint on staged composition
	lintCmd := exec.CommandContext(ctx, runtimePath, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	lintCmd.Dir = tempDir
	lintCmd.Env = env
	lintOut, err := lintCmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("lint staged composition failed: %w\n%s", err, string(lintOut))
	}

	// 2. Run acceptance command process fixture on bee:terminal host
	command := "window-hooks-acceptance"
	if *beeFlag != "" {
		command = "window-hooks-command-acceptance"
	} else if *pendingHook {
		command = "window-hooks-pending-acceptance"
	} else if *cancelRecovery {
		command = "window-hooks-cancel-recovery-acceptance"
	} else if *crash {
		command = "window-hooks-crash-acceptance"
	}
	cmd := exec.CommandContext(ctx, runtimePath, "run", "--host", "bee:terminal", "--", command)
	cmd.Dir = tempDir
	cmd.Env = env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 3 * time.Second
	started := time.Now()
	output, runErr := cmd.CombinedOutput()
	elapsed := time.Since(started).Round(time.Millisecond)
	outStr := string(output)
	if strings.Contains(outStr, "Bearer ") {
		return fmt.Errorf("credential header reached captured output")
	}

	if runErr != nil {
		// The exit reason distinguishes the fixture's own failure from the
		// harness deadline killing the process group.
		reason := runErr.Error()
		if cmd.ProcessState != nil {
			reason = cmd.ProcessState.String()
		}
		if ctx.Err() != nil {
			reason += " (harness deadline: " + ctx.Err().Error() + ")"
		}
		return fmt.Errorf("acceptance run on terminal host failed against %s (gateway endpoint: %s) after %s: %s\n--- acceptance output (%d bytes) ---\n%s\n--- end acceptance output ---",
			srcDir, endpoint, elapsed, reason, len(output), strings.TrimRight(outStr, "\n"))
	}

	if !strings.Contains(outStr, markerSuccess) {
		return fmt.Errorf("acceptance run finished without success marker:\n%s", outStr)
	}

	fmt.Printf("ACCEPTANCE PASSED against %s (gateway endpoint: %s):\n%s\n", srcDir, endpoint, strings.TrimSpace(outStr))
	return nil
}

func main() {
	if err := runHarness(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

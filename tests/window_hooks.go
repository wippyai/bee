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
	"time"
)

const (
	defaultRuntime = "/tmp/bee-runtime-native-recovery-20260911"
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

	// 2. Copy managed gateway HTTP definitions into src/managed
	gatewayManaged := filepath.Join(repoRoot, "tests", "modules", "gateway", "src", "managed")
	if err := copyDir(filepath.Join(tempDir, "src", "managed"), gatewayManaged); err != nil {
		return "", fmt.Errorf("copy gateway managed definitions: %w", err)
	}

	// 3. Copy window_hooks fixture into src/tests/window_hooks
	windowHooksFixture := filepath.Join(repoRoot, "tests", "fixtures", "window_hooks")
	if err := copyDir(filepath.Join(tempDir, "src", "tests", "window_hooks"), windowHooksFixture); err != nil {
		return "", fmt.Errorf("copy window_hooks fixture: %w", err)
	}

	// 4. Copy runtime config files
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		srcFile := filepath.Join(repoRoot, name)
		if _, err := os.Stat(srcFile); err == nil {
			if err := copyFile(filepath.Join(tempDir, name), srcFile); err != nil {
				return "", fmt.Errorf("copy %s: %w", name, err)
			}
		} else {
			// Fallback defaults if missing
			if name == ".wippy.yaml" {
				_ = os.WriteFile(filepath.Join(tempDir, name), []byte("version: '1.0'\nshutdown:\n  timeout: 3s\n"), 0644)
			} else {
				_ = os.WriteFile(filepath.Join(tempDir, name), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0644)
			}
		}
	}

	// 5. Pick ephemeral random loopback address for gateway
	endpointAddress, err := pickRandomLoopbackAddress()
	if err != nil {
		return "", fmt.Errorf("pick random loopback port: %w", err)
	}

	// 6. Patch src/_index.yaml with checked anchors
	hostFile := filepath.Join(tempDir, "src", "_index.yaml")
	hostBytes, err := os.ReadFile(hostFile)
	if err != nil {
		return "", fmt.Errorf("read _index.yaml: %w", err)
	}
	hostContent := string(hostBytes)

	addrAnchor := "address: 127.0.0.1:18790"
	if !strings.Contains(hostContent, addrAnchor) {
		return "", fmt.Errorf("missing anchor %q in _index.yaml", addrAnchor)
	}
	hostContent = strings.Replace(hostContent, addrAnchor, "address: "+endpointAddress, 1)

	readyAnchor := "http://127.0.0.1:18790/ready"
	if !strings.Contains(hostContent, readyAnchor) {
		return "", fmt.Errorf("missing anchor %q in _index.yaml", readyAnchor)
	}
	hostContent = strings.Replace(hostContent, readyAnchor, "http://"+endpointAddress+"/ready", 1)

	bindAnchor := "bindings: [bee.driver.claude:binding, bee.driver.codex:binding]"
	if !strings.Contains(hostContent, bindAnchor) {
		return "", fmt.Errorf("missing anchor %q in _index.yaml", bindAnchor)
	}
	hostContent = strings.Replace(hostContent, bindAnchor, "bindings: [bee.driver.claude:binding, bee.driver.codex:binding, bee.window_hooks_fixture:binding]", 1)
	hostContent = strings.Replace(hostContent, "hide_logs: true", "hide_logs: false", 1)

	if err := os.WriteFile(hostFile, []byte(hostContent), 0644); err != nil {
		return "", fmt.Errorf("write _index.yaml: %w", err)
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
	expectRed := flag.Bool("expect-red", false, "expect test to fail (for proving RED on integration lacking hook delivery)")
	keepTemp := flag.Bool("keep-temp", false, "do not delete temporary directory after run")
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
	cmd := exec.CommandContext(ctx, runtimePath, "run", "--host", "bee:terminal", "--", "window-hooks-acceptance")
	cmd.Dir = tempDir
	cmd.Env = env
	output, runErr := cmd.CombinedOutput()
	outStr := string(output)

	if *expectRed {
		if runErr == nil && strings.Contains(outStr, markerSuccess) {
			return fmt.Errorf("expected RED failure against %s, but acceptance passed unexpectedly:\n%s", srcDir, outStr)
		}
		fmt.Printf("PROVED MEANINGFUL RED against %s (gateway endpoint: %s):\n%s\n", srcDir, endpoint, outStr)
		return nil
	}

	if runErr != nil {
		return fmt.Errorf("acceptance run on terminal host failed against %s (gateway endpoint: %s): %w\n%s", srcDir, endpoint, runErr, outStr)
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

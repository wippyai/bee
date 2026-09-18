// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Proves native supervised service startup input can bootstrap the ACTUAL
// Bee Hive supervisor without giving ordinary applications supervisor host authority.
func TestHiveSupervisorServiceBootstrap(t *testing.T) {
	binary := os.Getenv("BEE_HIVE_SUPERVISOR_RUNTIME")
	if binary == "" {
		t.Skip("set BEE_HIVE_SUPERVISOR_RUNTIME for native supervisor service acceptance")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	transportTLS := supervisorTLS(t, root)
	frozenSource, _ := freezeHiveSupervisorSource(t, root)
	serviceFixture := filepath.Join(root, "service-fixture")
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate service bootstrap fixture")
	}
	fixtureSource := filepath.Join(filepath.Dir(sourceFile), "fixtures/hive_service_bootstrap")
	if err := os.CopyFS(serviceFixture, os.DirFS(fixtureSource)); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	secretString := base64.StdEncoding.EncodeToString(secret)
	keys := make([]string, 2)
	trusted := map[string]string{}
	for i := range keys {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		keys[i] = base64.RawStdEncoding.EncodeToString(priv)
		trusted[fmt.Sprintf("node-%d", i)] = base64.RawStdEncoding.EncodeToString(pub)
	}

	stage := func(i int, seed string) string {
		folder := filepath.Join(root, fmt.Sprintf("node-%d", i))
		srcDir := filepath.Join(folder, "src")
		if err := os.CopyFS(srcDir, os.DirFS(frozenSource)); err != nil {
			t.Fatal(err)
		}
		fixtureDir := filepath.Join(srcDir, "hive_service_bootstrap")
		if err := os.CopyFS(fixtureDir, os.DirFS(serviceFixture)); err != nil {
			t.Fatal(err)
		}
		// Observe the actual service security frame before entering production logic.
		// This test-only instrumentation adds no policies and never changes the scope.
		assertions, err := os.ReadFile(filepath.Join(fixtureDir, "startup_assertions.lua"))
		if err != nil {
			t.Fatal(err)
		}
		mainPath := filepath.Join(srcDir, "hive/supervisor/main.lua")
		mainSource, err := os.ReadFile(mainPath)
		if err != nil {
			t.Fatal(err)
		}
		anchor := "local function main(configuration: unknown)\n"
		if strings.Count(string(mainSource), anchor) != 1 {
			t.Fatal("supervisor startup assertion anchor changed")
		}
		observed := strings.Replace(string(mainSource), anchor, anchor+string(assertions)+"\n", 1)
		if err := os.WriteFile(mainPath, []byte(observed), 0600); err != nil {
			t.Fatal(err)
		}
		manifestPath := filepath.Join(srcDir, "hive/supervisor/_index.yaml")
		manifest, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Fatal(err)
		}
		modules := "modules: [process, channel, time, uuid, funcs, logger]"
		if strings.Count(string(manifest), modules) != 1 {
			t.Fatal("supervisor module assertion anchor changed")
		}
		observedManifest := strings.Replace(string(manifest), modules, "modules: [process, channel, time, uuid, funcs, logger, security]", 1)
		if err := os.WriteFile(manifestPath, []byte(observedManifest), 0600); err != nil {
			t.Fatal(err)
		}

		// Append the trusted native service configuration for the actual Bee Hive supervisor.
		// Service input injects the trusted peer nodes directly into the supervisor process.
		peerNode := fmt.Sprintf("node-%d", 1-i)
		serviceManifestSnippet := fmt.Sprintf(`
- name: hive_supervisor_service
  kind: process.service
  process: bee.hive.supervisor:main
  host: bee.hive:supervisor_host
  input:
  - configured_nodes:
    - %s
  lifecycle:
    auto_start: true
    security:
      actor:
        id: bee.hive.supervisor
      policies:
      - bee:hive_supervisor_policy
      - bee:hive_catalog_policy
      - bee:hive_exposure_policy
      - bee:hive_dispatch_policy
      - bee.hive_service_bootstrap:names_policy
      - bee.hive_service_bootstrap:execute_policy
  meta:
    type: test_support
`, peerNode)

		indexPath := filepath.Join(fixtureDir, "_index.yaml")
		f, err := os.OpenFile(indexPath, os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.WriteString(serviceManifestSnippet); err != nil {
			_ = f.Close()
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}

		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
			t.Fatal(err)
		}

		role, expected := "client", 0
		if i == 0 {
			role, expected = "server", 1
		}
		config := map[string]any{
			"version":  "1.0",
			"shutdown": map[string]any{"timeout": "2s"},
			"relay":    map[string]any{"node_name": fmt.Sprintf("node-%d", i)},
			"lua":      map[string]any{"type_system": map[string]any{"enabled": true, "strict": true}},
			"cluster": map[string]any{
				"enabled": true,
				"name":    fmt.Sprintf("node-%d", i),
				"raft": map[string]any{
					"role":             role,
					"bootstrap_expect": expected,
					"max_voters":       1,
					"max_standbys":     0,
					"data_dir":         filepath.Join(folder, "node-state"),
				},
				"membership": map[string]any{
					"bind_addr":  "127.0.0.1",
					"bind_port":  0,
					"join_addrs": seed,
					"secret_key": secretString,
				},
				"internode": map[string]any{
					"bind_addr":         "127.0.0.1",
					"bind_port":         0,
					"auto_port":         true,
					"identity_key":      keys[i],
					"trusted_peer_keys": trusted,
					"tls":               transportTLS,
				},
			},
		}
		data, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), data, 0600); err != nil {
			t.Fatal(err)
		}

		// Verify strict Lua lint on the exact staged fixture before runtime execution.
		lint := exec.CommandContext(ctx, binary, "lint", "--json")
		lint.Dir = folder
		if output, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("node %d lint: %v\n%s", i, err, sanitizeDiagnostics(string(output), secretString, keys))
		}
		return folder
	}

	start := func(i int, folder string) *procRunner {
		cmd := exec.CommandContext(ctx, binary, "run", "--silent", "hive-service-probe", "--", fmt.Sprintf("node-%d", 1-i))
		cmd.Dir = folder
		cmd.Env = append(os.Environ(), "GOMAXPROCS=2", "BEE_WORKSPACE_DB="+filepath.Join(folder, "workspace.db"), "BEE_THREADS_DB="+filepath.Join(folder, "threads.db"))
		runner, err := newProcRunner(cmd, fmt.Sprintf("service node %d", i))
		if err != nil {
			t.Fatal(err)
		}
		if err := runner.start(ctx, fmt.Sprintf("service node %d", i)); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := runner.stop(); err != nil {
				t.Errorf("node %d cleanup: %v", i, err)
			}
			if t.Failed() {
				t.Logf("node %d diagnostics:\n%s", i, sanitizeDiagnostics(runner.stderr.String(), secretString, keys))
			}
		})
		return runner
	}

	marker := func(runner *procRunner, expected string) string {
		for {
			select {
			case line, open := <-runner.collector.lines:
				if !open {
					t.Fatalf("node exited waiting for %s", expected)
				}
				if strings.HasPrefix(line, "BEE_HIVE_SERVICE "+expected) {
					return strings.TrimPrefix(line, "BEE_HIVE_SERVICE "+expected)
				}
			case <-ctx.Done():
				t.Fatalf("waiting for %s: %v", expected, ctx.Err())
			}
		}
	}

	command := func(runner *procRunner, cmd, expected string) {
		if _, err := io.WriteString(runner.stdin, cmd+"\n"); err != nil {
			t.Fatal(err)
		}
		marker(runner, expected)
	}

	// 1. Start Node 0 with auto-started native supervised Hive supervisor
	a := start(0, stage(0, ""))
	seed := marker(a, "ready ")

	// 2. Start Node 1 with auto-started native supervised Hive supervisor connected via seed
	b := start(1, stage(1, seed))
	marker(b, "ready ")

	// 3. Bidirectional remote telemetry verification
	command(a, "probe", "probe_passed")
	command(b, "probe", "probe_passed")

	// 4. Negative security audit: verify ordinary probe application has no supervisor host authority,
	// cannot spawn on supervisor host, register actor names, or cancel supervisor.
	command(a, "verify-security", "security_verified")
	command(b, "verify-security", "security_verified")

	// 5. Clean graceful termination: probe exits and runtime stops service cleanly
	command(b, "stop", "stopped")
	command(a, "stop", "stopped")

	if err := b.wait(5 * time.Second); err != nil {
		t.Fatalf("node 1 clean shutdown failed: %v", err)
	}
	if err := a.wait(5 * time.Second); err != nil {
		t.Fatalf("node 0 clean shutdown failed: %v", err)
	}

	t.Log("native supervised service startup: trusted input bootstraps actual supervisor, local name registered on protected host, bidirectional telemetry verified, security authority strictly denied to ordinary applications, clean shutdown")
}

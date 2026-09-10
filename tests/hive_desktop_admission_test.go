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

func TestHiveDesktopAdmission(t *testing.T) {
	binary := os.Getenv("BEE_HIVE_SUPERVISOR_RUNTIME")
	if binary == "" {
		t.Skip("set BEE_HIVE_SUPERVISOR_RUNTIME for native supervisor acceptance")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	nativeClient := os.Getenv("BEE_NATIVE_DESKTOP_CLIENT")
	if nativeClient != "" {
		nativeClient, err = filepath.Abs(nativeClient)
		if err != nil {
			t.Fatal(err)
		}
	}
	locations := desktopLocations(t, binary)
	root := t.TempDir()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate fixture source")
	}
	repository := filepath.Dir(filepath.Dir(sourceFile))
	sourceSnapshot := filepath.Join(root, "source")
	if err := os.CopyFS(sourceSnapshot, os.DirFS(filepath.Join(repository, "src"))); err != nil {
		t.Fatal(err)
	}
	// This headless owner has no physical console to protect from logs. Keep
	// lifecycle diagnostics visible when an actual client acceptance fails.
	rootManifest := filepath.Join(sourceSnapshot, "_index.yaml")
	manifest, err := os.ReadFile(rootManifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rootManifest, []byte(strings.ReplaceAll(string(manifest), "hide_logs: true", "hide_logs: false")), 0600); err != nil {
		t.Fatal(err)
	}
	fixtureSnapshot := filepath.Join(repository, "tests/fixtures/hive_desktop_admission")
	transportTLS := supervisorTLS(t, root, locations.hostAddress, locations.clientAddress)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	remote := newDesktopRemote(t, ctx, locations)
	var proofBytes [16]byte
	if _, err := rand.Read(proofBytes[:]); err != nil {
		t.Fatal(err)
	}
	ownerProof := fmt.Sprintf("%x", proofBytes)
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	secretString := base64.StdEncoding.EncodeToString(secret)
	keys := make([]string, 3)
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
		if err := os.CopyFS(filepath.Join(folder, "src"), os.DirFS(sourceSnapshot)); err != nil {
			t.Fatal(err)
		}
		if err := os.CopyFS(filepath.Join(folder, "src", "hive_probe"), os.DirFS(fixtureSnapshot)); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"transport.pem", "transport-key.pem"} {
			data, err := os.ReadFile(filepath.Join(root, name))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(folder, name), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		nodeTLS := map[string]any{"enabled": transportTLS["enabled"], "cert_file": "transport.pem", "key_file": "transport-key.pem", "ca_file": "transport.pem"}
		address := locations.clientAddress
		if i == 0 {
			address = locations.hostAddress
			if err := os.WriteFile(filepath.Join(folder, "desktop-owner-proof"), []byte(ownerProof+"\n"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		role, expected := "client", 0
		if i == 0 {
			role, expected = "server", 1
		}
		config := map[string]any{
			"version": "1.0", "shutdown": map[string]any{"timeout": "2s"},
			"relay": map[string]any{"node_name": fmt.Sprintf("node-%d", i)},
			"lua":   map[string]any{"type_system": map[string]any{"enabled": true, "strict": true}},
			"cluster": map[string]any{
				"enabled": true, "name": fmt.Sprintf("node-%d", i),
				"raft":       map[string]any{"role": role, "bootstrap_expect": expected, "max_voters": 1, "max_standbys": 0, "data_dir": "node-state"},
				"membership": map[string]any{"bind_addr": address, "advertise_addr": address, "bind_port": 0, "join_addrs": seed, "secret_key": secretString},
				"internode":  map[string]any{"bind_addr": address, "advertise_addr": address, "bind_port": 0, "auto_port": true, "identity_key": keys[i], "trusted_peer_keys": trusted, "tls": nodeTLS},
			},
		}
		data, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), data, 0600); err != nil {
			t.Fatal(err)
		}
		// Check the exact staged fixture before starting its runtime.
		lint := exec.CommandContext(ctx, binary, "lint", "--json")
		lint.Dir = folder
		if i == 0 && remote != nil {
			remote.stage(t, ctx, folder)
			lint = remote.lint(ctx)
		}
		if output, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("node %d lint: %v\n%s", i, err, sanitizeDiagnostics(string(output), secretString, keys))
		}
		return folder
	}
	rejoinDirectory := ""
	start := func(i int, folder string) *procRunner {
		cmd := exec.CommandContext(ctx, binary, "run", "--console", "hive-desktop-admission-probe", "--", fmt.Sprintf("node-%d", i))
		if i == 1 && nativeClient != "" {
			cmd = exec.CommandContext(ctx, nativeClient)
		}
		cmd.Dir = folder
		cmd.Env = append(os.Environ(), desktopDatabaseEnvironment(folder)...)
		if i == 1 {
			cmd.Env = append(cmd.Env, "BEE_NATIVE_DESKTOP_OWNER_PROOF="+ownerProof, "BEE_NATIVE_DESKTOP_REJOIN_DIR="+rejoinDirectory)
		}
		if i == 0 && remote != nil {
			cmd = remote.command(ctx)
		}
		runner, err := newProcRunner(cmd, fmt.Sprintf("supervisor node %d", i))
		if err != nil {
			t.Fatal(err)
		}
		if err := runner.start(ctx, fmt.Sprintf("supervisor node %d", i)); err != nil {
			t.Fatal(err)
		}
		if i == 0 && remote != nil {
			remote.started = true
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
				if strings.HasPrefix(line, "BEE_HIVE_SUPERVISOR "+expected) {
					return strings.TrimPrefix(line, "BEE_HIVE_SUPERVISOR "+expected)
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
	a := start(0, stage(0, ""))
	seed := marker(a, "ready ")
	clientDirectory := stage(1, seed)
	if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") == "1" {
		rejoinDirectory = stage(2, seed)
	}
	b := start(1, clientDirectory)
	marker(b, "ready ")
	command(b, "probe", "probe_passed")
	if nativeClient == "" {
		command(b, "crash", "probe_passed")
		command(b, "recover", "probe_passed")
		// More than the bridge's 64-client capacity: exited actors must release records.
		for i := 0; i < 66; i++ {
			command(b, "exit", "probe_passed")
		}
		command(b, "recover", "probe_passed")
	} else if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_BINARY") != "" {
		if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") == "1" {
			t.Log("physical native client: SIGKILL without detach, fresh process rejoin, retained shell variable, bounded detach and terminal attribute restoration")
		} else {
			t.Log("physical native client: shell input, F12 same-shell recovery, resize, bounded detach and terminal attribute restoration")
		}
	} else {
		t.Log("compiled native client: typed Hive admission and native viewport IO")
	}
	command(b, "stop", "stopped")
	command(a, "stop", "stopped")
	if err := b.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := a.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if remote != nil {
		t.Log("remote owner stopped and guarded fixture cleanup scheduled")
	}
	t.Log("native desktop admission completed against the actual retained owner")
}

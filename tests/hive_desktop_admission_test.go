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

	"gopkg.in/yaml.v3"
)

func TestHiveDesktopAdmission(t *testing.T) { runHiveDesktopAdmission(t, false) }

// Catalog/explicit-detach acceptance remains independent of the native exact
// remote actor EXIT gate exercised by TestHiveDesktopAdmission.
func TestHiveDesktopCatalog(t *testing.T) { runHiveDesktopAdmission(t, true) }

// The separate remote physical fixture starts its supervisor explicitly.
const desktopSupervisorOverride = "bee.hive.service:supervisor_service:lifecycle.auto_start=false"

// projectReplacements reads the component modules the project composes from
// source: its .wippy.yaml workspace replacements.
func projectReplacements(t *testing.T, repository string) map[string]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(repository, ".wippy.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var project struct {
		Workspace struct {
			Replacements map[string]string `yaml:"replacements"`
		} `yaml:"workspace"`
	}
	if err := yaml.Unmarshal(data, &project); err != nil {
		t.Fatal(err)
	}
	if len(project.Workspace.Replacements) == 0 {
		t.Fatal("the project composes no component modules")
	}
	return project.Workspace.Replacements
}

func runHiveDesktopAdmission(t *testing.T, catalogOnly bool) {
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
	if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_BINARY") != "" {
		// Mark actual presenter replacement in the disposable source. Identical
		// retained content need not emit fresh terminal bytes after F12.
		presenter := filepath.Join(sourceSnapshot, "core", "terminal", "main.lua")
		body, err := os.ReadFile(presenter)
		if err != nil {
			t.Fatal(err)
		}
		anchor := `"Workspace " .. names.label(workspace_id)`
		if strings.Count(string(body), anchor) != 1 {
			t.Fatal("unexpected presenter label anchor")
		}
		body = []byte(strings.Replace(string(body), anchor, anchor+` .. " P:" .. tostring(process.pid()):sub(-8)`, 1))
		if err := os.WriteFile(presenter, body, 0600); err != nil {
			t.Fatal(err)
		}
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
	// The full source composition needs every component module the project
	// replaces, with the project's own lock.
	replacements := projectReplacements(t, repository)
	lock, err := os.ReadFile(filepath.Join(repository, "wippy.lock"))
	if err != nil {
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
		if i == 0 {
			servicePath := filepath.Join(folder, "src", "hive", "service", "_index.yaml")
			service, err := os.ReadFile(servicePath)
			if err != nil {
				t.Fatal(err)
			}
			serviceAnchor := "  input:\n  - configured_nodes: []\n"
			expiry := time.Now().Add(5 * time.Minute).UTC().Format("2006-01-02T15:04:05.000Z")
			input := serviceAnchor + "    desktop:\n      execution: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n      expires_at: '" + expiry + "'\n      allowed_nodes: [node-1, node-2]\n      application: bee.console:app\n"
			if strings.Count(string(service), serviceAnchor) != 1 {
				t.Fatal("desktop supervisor input anchor changed")
			}
			if err := os.WriteFile(servicePath, []byte(strings.Replace(string(service), serviceAnchor, input, 1)), 0600); err != nil {
				t.Fatal(err)
			}
			// Report the exact owner's completed controller revocation to the
			// acceptance. A local EXIT and its remote release are independent events.
			path := filepath.Join(folder, "src", "launch", "supervisor.lua")
			body, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			anchor := `                        if request.op == "attach" then result = attachments.attach(selected_desktop.grants, request.recipient, request.mode)
                        else result = attachments.detach(selected_desktop.grants, request.recipient) end`
			probe := `                        local was_controller = selected_desktop.grants.controller and selected_desktop.grants.controller.recipient == request.recipient
                        if request.op == "attach" then result = attachments.attach(selected_desktop.grants, request.recipient, request.mode)
                        else result = attachments.detach(selected_desktop.grants, request.recipient) end
                        if request.op == "detach" and was_controller and result.error_code == "" then
                            process.send("bee.desktop.admission.probe.release", "bee.desktop.fixture.released", {recipient = request.recipient})
                        end`
			if strings.Count(string(body), anchor) != 1 {
				t.Fatal("controller release probe anchor changed")
			}
			if err := os.WriteFile(path, []byte(strings.Replace(string(body), anchor, probe, 1)), 0600); err != nil {
				t.Fatal(err)
			}
		}
		for _, module := range replacements {
			if err := os.CopyFS(filepath.Join(folder, module), os.DirFS(filepath.Join(repository, module))); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.CopyFS(filepath.Join(folder, "src", "hive_probe"), os.DirFS(fixtureSnapshot)); err != nil {
			t.Fatal(err)
		}
		ownerOS := "Linux"
		if remote != nil {
			ownerOS = remote.platform
		} else if runtime.GOOS == "darwin" {
			ownerOS = "Darwin"
		}
		clientFixture := filepath.Join(folder, "src", "hive_probe", "client.lua")
		clientSource, err := os.ReadFile(clientFixture)
		if err != nil {
			t.Fatal(err)
		}
		text := string(clientSource)
		if strings.Count(text, "__BEE_OWNER_OS__") != 1 || strings.Count(text, "__BEE_OWNER_PROOF__") != 1 {
			t.Fatal("missing destination proof markers")
		}
		text = strings.ReplaceAll(strings.ReplaceAll(text, "__BEE_OWNER_OS__", ownerOS), "__BEE_OWNER_PROOF__", ownerProof)
		if err := os.WriteFile(clientFixture, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), lock, 0600); err != nil {
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
			"workspace": map[string]any{"replacements": replacements},
			"relay":     map[string]any{"node_name": fmt.Sprintf("node-%d", i)},
			"lua":       map[string]any{"type_system": map[string]any{"enabled": true, "strict": true}},
			"cluster": map[string]any{
				"enabled": true, "name": fmt.Sprintf("node-%d", i),
				"raft":       map[string]any{"role": role, "bootstrap_expect": expected, "max_voters": 1, "max_standbys": 0, "data_dir": "node-state"},
				"membership": map[string]any{"bind_addr": address, "advertise_addr": address, "bind_port": 0, "join_addrs": seed, "secret_key": secretString},
				"internode":  map[string]any{"bind_addr": address, "bind_port": 0, "auto_port": true, "identity_key": keys[i], "trusted_peer_keys": trusted, "tls": nodeTLS},
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
	command := func(runner *procRunner, cmd, expected string) string {
		if _, err := io.WriteString(runner.stdin, cmd+"\n"); err != nil {
			t.Fatal(err)
		}
		return marker(runner, expected)
	}
	a := start(0, stage(0, ""))
	seed := marker(a, "ready ")
	clientDirectory := stage(1, seed)
	if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") == "1" || os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_OBSERVER") == "1" {
		rejoinDirectory = stage(2, seed)
	}
	b := start(1, clientDirectory)
	marker(b, "ready ")
	command(b, "probe", "probe_passed")
	if catalogOnly {
		t.Log("catalog, controller and observer authority, controller conflict, detach/rejoin, and retained shell state passed")
	} else if nativeClient == "" {
		crashed := strings.TrimSpace(command(b, "crash", "probe_passed"))
		command(a, "await_release "+crashed, "released "+crashed)
		command(b, "recover", "probe_passed")
		// More than the bridge's 64-client capacity: exited actors must release records.
		for i := 0; i < 66; i++ {
			exited := strings.TrimSpace(command(b, "exit", "probe_passed"))
			command(a, "await_release "+exited, "released "+exited)
		}
		command(b, "recover", "probe_passed")
	} else if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_BINARY") != "" {
		if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") == "1" {
			t.Log("physical native client: SIGKILL without detach, fresh process rejoin, retained shell variable, bounded detach and terminal attribute restoration")
		} else if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_OBSERVER") == "1" {
			t.Log("physical native clients: shared shell observation, denied observer input/resize, observer detach preserves controller, F12 and resize")
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

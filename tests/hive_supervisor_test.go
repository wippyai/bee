// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func stageHiveSupervisorDesktop(t *testing.T, source string) {
	t.Helper()
	path := filepath.Join(source, "hive", "desktop", "_index.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Version   string                   `yaml:"version"`
		Namespace string                   `yaml:"namespace"`
		Entries   []map[string]interface{} `yaml:"entries"`
	}
	if err := yaml.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("decode Hive desktop fixture manifest: %v", err)
	}
	if manifest.Namespace != "bee.hive.desktop" {
		t.Fatalf("Hive desktop fixture namespace = %q", manifest.Namespace)
	}
	wanted := map[string]bool{"protocol": true, "catalog": true, "owner": true, "host_policy": true}
	entries := make([]map[string]interface{}, 0, len(wanted))
	for _, entry := range manifest.Entries {
		name, _ := entry["name"].(string)
		if wanted[name] {
			entries = append(entries, entry)
			delete(wanted, name)
		}
	}
	if len(wanted) != 0 {
		t.Fatalf("Hive desktop fixture is missing bridge entries: %v", wanted)
	}
	manifest.Entries = entries
	data, err = yaml.Marshal(&manifest)
	if err != nil {
		t.Fatalf("encode Hive desktop fixture manifest: %v", err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

// Uses actual native peer authentication and process provenance. The only
// configured identities are native nodes; no supervisor PID is passed at boot.
func freezeHiveSupervisorSource(t *testing.T, root string, includeDefaultService bool) (string, string) {
	t.Helper()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate supervisor fixture sources")
	}
	repository, err := filepath.Abs(filepath.Dir(filepath.Dir(sourceFile)))
	if err != nil {
		t.Fatal(err)
	}
	sourceSnapshot := filepath.Join(root, "source")
	fixtureSnapshot := filepath.Join(root, "fixture")
	if err := os.CopyFS(filepath.Join(sourceSnapshot, "hive"), os.DirFS(filepath.Join(repository, "src/hive"))); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"hive", "persist", "sync", "threads"} {
		if err := os.CopyFS(filepath.Join(root, "modules", name), os.DirFS(filepath.Join(repository, "modules", name))); err != nil {
			t.Fatal(err)
		}
	}
	stageHiveSupervisorDesktop(t, sourceSnapshot)
	if err := os.CopyFS(fixtureSnapshot, os.DirFS(filepath.Join(repository, "tests/fixtures/hive_supervisor"))); err != nil {
		t.Fatal(err)
	}
	for _, dependency := range []struct{ directory, source, manifest string }{
		{"application_arguments", "modules/application/src/arguments.lua", "version: '1.0'\nnamespace: bee.application\nentries:\n- name: arguments\n  kind: library.lua\n  source: file://source.lua\n"},
		{"application_protocol", "src/core/protocol/application.lua", "version: '1.0'\nnamespace: bee.protocol\nentries:\n- name: application\n  kind: library.lua\n  source: file://source.lua\n  imports:\n    arguments: bee.application:arguments\n"},
		{"retained_protocol", "src/core/launch/retained_protocol.lua", "version: '1.0'\nnamespace: bee.launch\nentries:\n- name: retained_protocol\n  kind: library.lua\n  source: file://source.lua\n  imports:\n    contract: bee.protocol:application\n"},
	} {
		directory := filepath.Join(sourceSnapshot, dependency.directory)
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		body, err := os.ReadFile(filepath.Join(repository, dependency.source))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, "source.lua"), body, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, "_index.yaml"), []byte(dependency.manifest), 0600); err != nil {
			t.Fatal(err)
		}
	}
	applicationManifest := filepath.Join(sourceSnapshot, "application_protocol/_index.yaml")
	application, err := os.ReadFile(applicationManifest)
	if err != nil {
		t.Fatal(err)
	}
	application = append(application, []byte("    thread_bounds: bee.threads.records:bounds\n")...)
	if err := os.WriteFile(applicationManifest, application, 0600); err != nil {
		t.Fatal(err)
	}
	retainedManifest := filepath.Join(sourceSnapshot, "retained_protocol/_index.yaml")
	retained, err := os.ReadFile(retainedManifest)
	if err != nil {
		t.Fatal(err)
	}
	retained = append(retained, []byte("    arguments: bee.application:arguments\n    clipboard: bee.client:clipboard\n")...)
	if err := os.WriteFile(retainedManifest, retained, 0600); err != nil {
		t.Fatal(err)
	}
	clipboard, err := os.ReadFile(filepath.Join(repository, "src/core/client/clipboard.lua"))
	if err != nil {
		t.Fatal(err)
	}
	clipboardDir := filepath.Join(sourceSnapshot, "clipboard")
	if err := os.MkdirAll(clipboardDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(clipboardDir, "clipboard.lua"), clipboard, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(clipboardDir, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.client\nentries:\n- name: clipboard\n  kind: library.lua\n  source: file://clipboard.lua\n"), 0600); err != nil {
		t.Fatal(err)
	}
	appearance, err := os.ReadFile(filepath.Join(repository, "modules/application/src/appearance.lua"))
	if err != nil {
		t.Fatal(err)
	}
	appearanceDir := filepath.Join(sourceSnapshot, "appearance")
	if err := os.MkdirAll(appearanceDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(appearanceDir, "appearance.lua"), appearance, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(appearanceDir, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.application\nentries:\n- name: appearance\n  kind: library.lua\n  source: file://appearance.lua\n"), 0600); err != nil {
		t.Fatal(err)
	}
	host, err := os.ReadFile(filepath.Join(fixtureSnapshot, "host.manifest"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourceSnapshot, "_index.yaml"), host, 0600); err != nil {
		t.Fatal(err)
	}
	return sourceSnapshot, fixtureSnapshot
}

// supervisorTLS uses disposable loopback credentials for native transport only.
// Native node signing identities remain separate and independently checked.
func supervisorTLS(t *testing.T, root string, addresses ...string) map[string]any {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Bee supervisor fixture"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true,
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	for _, address := range addresses {
		ip := net.ParseIP(address)
		if ip == nil {
			t.Fatalf("invalid fixture TLS address %q", address)
		}
		template.IPAddresses = append(template.IPAddresses, ip)
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certFile, keyFile := filepath.Join(root, "transport.pem"), filepath.Join(root, "transport-key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), 0600); err != nil {
		t.Fatal(err)
	}
	return map[string]any{"enabled": true, "cert_file": certFile, "key_file": keyFile, "ca_file": certFile}
}

func TestHiveSupervisors(t *testing.T) {
	runHiveSupervisors(t, false)
}

func TestHiveSupervisorFeeds(t *testing.T) {
	runHiveSupervisors(t, true)
}

func stageHiveFeeds(t *testing.T, source, fixture string) {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	repository, err := filepath.Abs(filepath.Dir(filepath.Dir(file)))
	if err != nil {
		t.Fatal(err)
	}
	coordinatorPath := filepath.Join(fixture, "coordinator.lua")
	coordinator, err := os.ReadFile(coordinatorPath)
	if err != nil {
		t.Fatal(err)
	}
	coordinator = []byte(strings.Replace(string(coordinator), `funcs.new():call("bee.feed_probe:handle", {command = command, remote = remote})`, `require("feed_logic").handle({command = command, remote = remote})`, 1))
	if err := os.WriteFile(coordinatorPath, coordinator, 0600); err != nil {
		t.Fatal(err)
	}
	fixtureManifest := filepath.Join(fixture, "_index.yaml")
	fixtureBytes, err := os.ReadFile(fixtureManifest)
	if err != nil {
		t.Fatal(err)
	}
	fixtureText := strings.Replace(string(fixtureBytes), "    types: bee.hive:types", "    feed_logic: bee.feed_probe:logic\n    types: bee.hive:types", 1)
	fixtureText = strings.Replace(fixtureText, "bee.hive_probe:name_injection_policy]", "bee.hive_probe:name_injection_policy, bee.feed_probe:policy, bee.feed_probe:enrollment_policy]", 1)
	if err := os.WriteFile(fixtureManifest, []byte(fixtureText), 0600); err != nil {
		t.Fatal(err)
	}
	hostDir := filepath.Join(source, "hive", "host")
	if err := os.RemoveAll(hostDir); err != nil {
		t.Fatal(err)
	}
	if err := os.CopyFS(hostDir, os.DirFS(filepath.Join(repository, "src", "hive", "host"))); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"application", "node"} {
		if err := os.CopyFS(filepath.Join(filepath.Dir(source), "modules", name), os.DirFS(filepath.Join(repository, "modules", name))); err != nil {
			t.Fatal(err)
		}
	}
	for _, directory := range []string{"application_arguments", "appearance"} {
		if err := os.RemoveAll(filepath.Join(source, directory)); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.CopyFS(filepath.Join(source, "approvals", "host"), os.DirFS(filepath.Join(repository, "src/approvals/host"))); err != nil {
		t.Fatal(err)
	}
	if err := os.CopyFS(filepath.Join(filepath.Dir(source), "modules", "approvals"), os.DirFS(filepath.Join(repository, "modules", "approvals"))); err != nil {
		t.Fatal(err)
	}
	if err := os.CopyFS(filepath.Join(source, "feed_fixture"), os.DirFS(filepath.Join(repository, "tests/fixtures/hive_feeds"))); err != nil {
		t.Fatal(err)
	}
}

func runHiveSupervisors(t *testing.T, feeds bool) {
	binary := os.Getenv("BEE_HIVE_SUPERVISOR_RUNTIME")
	if binary == "" {
		t.Skip("set BEE_HIVE_SUPERVISOR_RUNTIME for native supervisor acceptance")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	sourceSnapshot, fixtureSnapshot := freezeHiveSupervisorSource(t, root, false)
	if feeds {
		stageHiveFeeds(t, sourceSnapshot, fixtureSnapshot)
	}
	transportTLS := supervisorTLS(t, root)
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
		if err := os.CopyFS(filepath.Join(folder, "src"), os.DirFS(sourceSnapshot)); err != nil {
			t.Fatal(err)
		}
		if err := os.CopyFS(filepath.Join(folder, "src", "hive_probe"), os.DirFS(fixtureSnapshot)); err != nil {
			t.Fatal(err)
		}
		moduleNames := []string{"hive", "persist", "sync", "threads"}
		if feeds {
			moduleNames = append(moduleNames, "application", "approvals", "node")
		}
		for _, name := range moduleNames {
			if err := os.CopyFS(filepath.Join(folder, "modules", name), os.DirFS(filepath.Join(root, "modules", name))); err != nil {
				t.Fatal(err)
			}
		}
		lock := "directories:\n  modules: .wippy\n  src: ./src\nmodules:\n"
		for _, name := range moduleNames {
			lock += "- name: bee/" + name + "\n  version: 0.1.0-dev\n"
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte(lock), 0600); err != nil {
			t.Fatal(err)
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
				"raft":       map[string]any{"role": role, "bootstrap_expect": expected, "max_voters": 1, "max_standbys": 0, "data_dir": filepath.Join(folder, "node-state")},
				"membership": map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "join_addrs": seed, "secret_key": secretString},
				"internode":  map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "auto_port": true, "identity_key": keys[i], "trusted_peer_keys": trusted, "tls": transportTLS},
			},
		}
		replacements := map[string]string{}
		for _, name := range moduleNames {
			replacements["bee/"+name] = "./modules/" + name
		}
		config["workspace"] = map[string]any{"replacements": replacements}
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
		if output, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("node %d lint: %v\n%s", i, err, sanitizeDiagnostics(string(output), secretString, keys))
		}
		return folder
	}
	start := func(i int, folder string) *procRunner {
		verbosity := "--silent"
		if feeds {
			verbosity = "--verbose"
		}
		args := []string{"run", verbosity}
		args = append(args, "--override", "bee.hive.host:supervisor_service:lifecycle.auto_start=false")
		if feeds {
			for _, service := range []string{"bee.approvals.service:worker_service", "bee.threads:owner_service", "bee.threads.delivery:waiter_service"} {
				args = append(args, "--override", service+":lifecycle.auto_start=false")
			}
		}
		args = append(args, "hive-supervisor-probe", "--", fmt.Sprintf("node-%d", 1-i))
		cmd := exec.CommandContext(ctx, binary, args...)
		cmd.Dir = folder
		cmd.Env = append(os.Environ(), "GOMAXPROCS=2", "BEE_WORKSPACE_DB="+filepath.Join(folder, "workspace.db"), "BEE_THREADS_DB="+filepath.Join(folder, "threads.db"), "BEE_SYNC_DB="+filepath.Join(folder, "sync.db"))
		if feeds {
			cmd.Env = append(cmd.Env, "BEE_APPROVALS_DB="+filepath.Join(folder, "approvals.db"), "BEE_NODE_DB="+filepath.Join(folder, "node.db"))
		}
		runner, err := newProcRunner(cmd, fmt.Sprintf("supervisor node %d", i))
		if err != nil {
			t.Fatal(err)
		}
		if err := runner.start(ctx, fmt.Sprintf("supervisor node %d", i)); err != nil {
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
	b := start(1, stage(1, seed))
	marker(b, "ready ")
	command(a, "probe", "probe_passed")
	command(b, "probe", "probe_passed")
	if feeds {
		command(b, "feed-denied", "feed_denied")
		if _, err := io.WriteString(b.stdin, "identity\n"); err != nil {
			t.Fatal(err)
		}
		subject := marker(b, "identity ")
		command(a, "enroll-read "+subject, "enrolled")
		command(b, "feed-read", "feed_read")
		command(b, "feed-write-denied", "feed_write_denied")
		command(a, "enroll-write "+subject, "enrolled")
		command(b, "feed-write", "feed_write")
		command(b, "feed-replay", "feed_replay")
		command(b, "feed-snapshot", "feed_snapshot")
		command(a, "approval-create "+subject, "approval_created")
		command(b, "feed-approval", "feed_approval")
		command(a, "approval-revoke", "approval_revoked")
		command(b, "feed-approval-empty", "feed_approval_empty")
		command(a, "revoke", "revoked")
		command(b, "feed-denied", "feed_denied")
	}
	command(b, "sibling", "sibling_denied")
	command(b, "check-name", "foreign_name_denied")
	command(b, "restart", "restarted")
	command(b, "probe", "probe_passed")
	command(a, "restart", "restarted")
	command(b, "probe", "probe_passed")
	command(a, "probe", "probe_passed")
	command(b, "stop", "stopped")
	command(a, "stop", "stopped")
	if err := b.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := a.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	t.Log("two native supervisors: node-qualified discovery, bidirectional telemetry, resource refusal, sibling and foreign-name denial, fresh-PID restart")
}

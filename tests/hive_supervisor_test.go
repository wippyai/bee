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
)

// The staged host admits node-0 to the telemetry stats operation on every
// node; node-1 stays outside the audience while presence stays unlisted.
func stageHiveExposureAudiences(t *testing.T, source string) {
	t.Helper()
	path := filepath.Join(source, "hive", "supervisor", "_index.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	anchor := "  data:\n    audiences: []"
	if strings.Count(string(data), anchor) != 1 {
		t.Fatal("staged Hive supervisor has no default exposure_audiences entry")
	}
	staged := strings.Replace(string(data), anchor,
		"  data:\n    audiences:\n    - operation_ref: bee.hive.telemetry.binding:stats\n      peers: [node-0]", 1)
	if err := os.WriteFile(path, []byte(staged), 0600); err != nil {
		t.Fatal(err)
	}
}

// Uses actual native peer authentication and process provenance. The only
// configured identities are native nodes; no supervisor PID is passed at boot.
func freezeHiveSupervisorSource(t *testing.T, root string) (string, string) {
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
	// This supervisor composition has no desktop app lifecycle. Telemetry and
	// desktop values use the application SDK and shared UI packages.
	if err := os.RemoveAll(filepath.Join(sourceSnapshot, "hive", "manager")); err != nil {
		t.Fatal(err)
	}
	// The staged supervisor boots the production service declaration, so it
	// stages the production app policies the service lifecycle selects.
	if err := os.CopyFS(filepath.Join(sourceSnapshot, "security"), os.DirFS(filepath.Join(repository, "src/security"))); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"values", "hive", "persist", "sync", "threads", "hive-telemetry", "application", "ui"} {
		if err := os.CopyFS(filepath.Join(root, "modules", name), os.DirFS(filepath.Join(repository, "modules", name))); err != nil {
			t.Fatal(err)
		}
	}
	stageHiveExposureAudiences(t, sourceSnapshot)
	if err := os.CopyFS(fixtureSnapshot, os.DirFS(filepath.Join(repository, "tests/fixtures/hive_supervisor"))); err != nil {
		t.Fatal(err)
	}
	host, err := os.ReadFile(filepath.Join(fixtureSnapshot, "host.manifest"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourceSnapshot, "_index.yaml"), host, 0600); err != nil {
		t.Fatal(err)
	}
	composition, err := os.ReadFile(filepath.Join(repository, "src", "deps", "_index.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	start := strings.Index(string(composition), "- name: hive\n")
	end := strings.Index(string(composition), "- name: hive_telemetry\n")
	if start < 0 || end <= start {
		t.Fatal("production Hive dependency selection is missing")
	}
	deps := filepath.Join(sourceSnapshot, "deps")
	if err := os.MkdirAll(deps, 0700); err != nil {
		t.Fatal(err)
	}
	selected := "version: '1.0'\nnamespace: bee.deps\nentries:\n" + string(composition)[start:end]
	if err := os.WriteFile(filepath.Join(deps, "_index.yaml"), []byte(selected), 0600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("python3", filepath.Join(repository, "tests", "hive_component_fixture.py"), root, sourceSnapshot)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("compose Hive host libraries: %v\n%s", err, output)
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
	coordinator = []byte(strings.Replace(string(coordinator), `funcs.new():call("bee.feed.probe:handle", {command = command, remote = remote})`, `require("feed_logic").handle({command = command, remote = remote})`, 1))
	if err := os.WriteFile(coordinatorPath, coordinator, 0600); err != nil {
		t.Fatal(err)
	}
	fixtureManifest := filepath.Join(fixture, "_index.yaml")
	fixtureBytes, err := os.ReadFile(fixtureManifest)
	if err != nil {
		t.Fatal(err)
	}
	fixtureText := strings.Replace(string(fixtureBytes), "    types: bee.hive:types", "    feed_logic: bee.feed.probe:logic\n    types: bee.hive:types", 1)
	fixtureText = strings.Replace(fixtureText, "bee.hive.probe:name_injection_policy]", "bee.hive.probe:name_injection_policy, bee.feed.probe:policy, bee.feed.probe:enrollment_policy]", 1)
	if err := os.WriteFile(fixtureManifest, []byte(fixtureText), 0600); err != nil {
		t.Fatal(err)
	}
	// The application libraries already ride the base module list for the
	// hive-telemetry package; the feeds composition adds only node here.
	for _, name := range []string{"node"} {
		if err := os.CopyFS(filepath.Join(filepath.Dir(source), "modules", name), os.DirFS(filepath.Join(repository, "modules", name))); err != nil {
			t.Fatal(err)
		}
	}
	// The feeds composition stages the production approver policies from the
	// app root, where the host owns them, instead of a module-side folder.
	rootIndex, err := os.ReadFile(filepath.Join(repository, "src", "security", "approvals", "_index.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rootIndex), "- name: approver_policies\n") {
		t.Fatal("production approver policies are missing")
	}
	stagedRoot := filepath.Join(source, "_index.yaml")
	// The approvals module takes its policies only through the dependency,
	// mirroring the production bee.deps wiring.
	staged, err := os.ReadFile(stagedRoot)
	if err != nil {
		t.Fatal(err)
	}
	dependency := "- name: dependency_approvals\n  kind: ns.dependency\n  component: bee/approvals\n" +
		"  version: 0.1.0-dev\n  parameters:\n  - name: target_db\n    value: bee.approvals.env:db\n" +
		"  - name: target_policies\n    value: bee.security.approvals:approver_policies\n" +
		"  - name: process_host\n    value: bee:workers\n" +
		"  - name: authority_policies\n    value: [bee.security.approvals:approval_store_policy, bee.security.approvals:approval_owner_policy]\n" +
		"  - name: worker_policies\n    value: [bee.security.approvals:approval_store_policy, bee.security.approvals:approval_owner_policy,\n" +
		"      bee.security.threads:thread_approval_policy, bee.security.threads:thread_approval_client_policy]\n" +
		"  - name: target_request_policies\n    value: [bee.security.approvals:approval_store_policy]\n"
	if err := os.WriteFile(stagedRoot, append(staged, []byte(dependency)...), 0600); err != nil {
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
	sourceSnapshot, fixtureSnapshot := freezeHiveSupervisorSource(t, root)
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
		moduleNames := []string{"values", "hive", "persist", "sync", "threads", "hive-telemetry", "application", "ui"}
		if feeds {
			moduleNames = append(moduleNames, "approvals", "node")
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
				"raft": map[string]any{"role": role, "bootstrap_expect": expected, "max_voters": 1, "max_standbys": 0,
					"heartbeat_timeout": "300ms", "election_timeout": "300ms", "data_dir": filepath.Join(folder, "node-state")},
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
		args = append(args, "--override", "bee.hive.service:supervisor_service:lifecycle.auto_start=false")
		if feeds {
			for _, service := range []string{"bee.approvals.service:worker_service", "bee.threads.service:owner_service", "bee.threads.service:waiter_service"} {
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
	// Telemetry exposure arrives through the staged install grant, not the
	// static ceiling: stats admits only its audience peer while unlisted
	// presence stays open to both.
	command(a, "expose-stats", "stats_ok")
	command(b, "expose-stats", "stats_denied")
	command(a, "expose-presence", "presence_ok")
	command(b, "expose-presence", "presence_ok")
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
		command(b, "feed-approval", "feed_approval_refused")
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

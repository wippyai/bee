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

// TestHiveSupervisorReplica exercises the production publisher, automatic
// distribution worker, node-authenticated replica admission, destination
// availability and explicit local stage/review/activation across two runtimes.
func TestHiveSupervisorReplica(t *testing.T) {
	binary := os.Getenv("BEE_HIVE_SUPERVISOR_RUNTIME")
	if binary == "" {
		t.Skip("set BEE_HIVE_SUPERVISOR_RUNTIME for native replica acceptance")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate replica fixture")
	}
	repository := filepath.Dir(filepath.Dir(sourceFile))
	root := t.TempDir()
	transportTLS := supervisorTLS(t, root)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
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
	nodeEnvironment := func(folder string) []string {
		// The standalone native host normally supplies these host-bound values.
		// This fixture runs the assembled runtime directly, so provide inert,
		// existing executable values to keep its production registry complete.
		return append(append(os.Environ(), beeDataEnv(folder)...),
			"home="+folder, "self="+binary, "agy="+binary, "claude="+binary,
			"codex="+binary, "grok="+binary, "ANTHROPIC_API_KEY=fixture-only")
	}
	stage := func(i int, seed string) string {
		folder := filepath.Join(root, fmt.Sprintf("node-%d", i))
		if err := os.CopyFS(filepath.Join(folder, "src"), os.DirFS(filepath.Join(repository, "src"))); err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			governancePath := filepath.Join(folder, "src", "governance", "_index.yaml")
			governance, err := os.ReadFile(governancePath)
			if err != nil {
				t.Fatal(err)
			}
			oldProfiles := "- name: activation_profiles\n  kind: registry.entry\n  meta:\n    type: bee.governance.activation_profiles\n    comment: Host-selected destination mappings and capability ceilings; remote artifacts cannot edit this entry\n  data: {profiles: []}"
			newProfiles := "- name: activation_profiles\n  kind: registry.entry\n  meta:\n    type: bee.governance.activation_profiles\n    comment: Host-selected destination mappings and capability ceilings; remote artifacts cannot edit this entry\n  data:\n    profiles:\n    - workspace_id: workspace-node-0\n      source_node: node-1\n      source_workspace: shared/application\n      component: private/bee-demo\n      resolver: overlay\n      overlay_owner: bee.replica_probe:activation_overlay\n      approval_policy: local-install\n      parameters: []\n      allow:\n        packages: [private/bee-demo]\n        namespaces: [private.bee_demo]\n        kinds: [function.lua]\n        databases: []\n        grants: []\n        modules: []"
			updated := strings.Replace(string(governance), oldProfiles, newProfiles, 1)
			if updated == string(governance) {
				t.Fatal("stage destination activation profile")
			}
			if err := os.WriteFile(governancePath, []byte(updated), 0600); err != nil {
				t.Fatal(err)
			}

			approvalsPath := filepath.Join(folder, "src", "approvals", "_index.yaml")
			approvals, err := os.ReadFile(approvalsPath)
			if err != nil {
				t.Fatal(err)
			}
			oldApprovers := "- name: approver_policies\n  kind: registry.entry\n  meta:\n    type: bee.approval_policies\n    comment: Host-owned approver policies; an empty list admits no request\n  policies: []"
			newApprovers := "- name: approver_policies\n  kind: registry.entry\n  meta:\n    type: bee.approval_policies\n    comment: Host-owned approver policies; an empty list admits no request\n  policies:\n  - name: local-install\n    approvers: [bee.replica_probe]\n    max_ttl_ms: 60000"
			updated = strings.Replace(string(approvals), oldApprovers, newApprovers, 1)
			if updated == string(approvals) {
				t.Fatal("stage destination approval profile")
			}
			if err := os.WriteFile(approvalsPath, []byte(updated), 0600); err != nil {
				t.Fatal(err)
			}
		}
		// The fixture owns the supervisor lifecycle and peer list. Production's
		// native activation entry would start a second local-only supervisor.
		if err := os.RemoveAll(filepath.Join(folder, "src", "hive_activation")); err != nil {
			t.Fatal(err)
		}
		if err := os.CopyFS(filepath.Join(folder, "src", "replica_probe"), os.DirFS(filepath.Join(repository, "tests/fixtures/hive_replica"))); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
			t.Fatal(err)
		}
		project, err := os.ReadFile(filepath.Join(repository, "wippy.yaml"))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, "wippy.yaml"), project, 0600); err != nil {
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
		data, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), data, 0600); err != nil {
			t.Fatal(err)
		}
		lint := exec.CommandContext(ctx, binary, "lint", "--json")
		lint.Dir = folder
		lint.Env = nodeEnvironment(folder)
		if output, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("node %d lint: %v\n%s", i, err, sanitizeDiagnostics(string(output), secretString, keys))
		}
		return folder
	}
	start := func(i int, folder string) *procRunner {
		cmd := exec.CommandContext(ctx, binary, "run", "--silent", "hive-replica-probe", "--", fmt.Sprintf("node-%d", 1-i))
		cmd.Dir = folder
		cmd.Env = append(nodeEnvironment(folder), "GOMAXPROCS=2")
		runner, err := newProcRunner(cmd, fmt.Sprintf("replica node %d", i))
		if err != nil {
			t.Fatal(err)
		}
		if err := runner.start(ctx, fmt.Sprintf("replica node %d", i)); err != nil {
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
	command := func(runner *procRunner, input, expected string) {
		if _, err := io.WriteString(runner.stdin, input+"\n"); err != nil {
			t.Fatal(err)
		}
		marker(runner, expected)
	}
	setJoinSeed := func(folder, seed string) {
		path := filepath.Join(folder, ".wippy.yaml")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var config map[string]any
		if err := json.Unmarshal(data, &config); err != nil {
			t.Fatal(err)
		}
		cluster, ok := config["cluster"].(map[string]any)
		if !ok {
			t.Fatal("replica fixture cluster configuration is missing")
		}
		membership, ok := cluster["membership"].(map[string]any)
		if !ok {
			t.Fatal("replica fixture membership configuration is missing")
		}
		membership["join_addrs"] = seed
		updated, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, updated, 0600); err != nil {
			t.Fatal(err)
		}
	}

	destinationFolder := stage(0, "")
	destination := start(0, destinationFolder)
	seed := marker(destination, "ready ")
	source := start(1, stage(1, seed))
	sourceSeed := marker(source, "ready ")
	command(destination, "probe", "probe_passed")
	command(source, "probe", "probe_passed")
	command(source, "replica-unmapped", "replica_unmapped")
	command(destination, "replica-read", "replica_exact")
	command(source, "replica-source-mismatch", "replica_source_mismatch")
	command(source, "replica-publish", "replica_published")
	command(destination, "replica-available", "replica_available")

	command(source, "application-publish-v1", "application_published_v1")
	command(destination, "application-available-v1", "application_available_v1")
	command(destination, "application-stage-public-v1", "application_staged_public_v1")
	command(destination, "application-select-v1", "application_selected_v1")
	command(destination, "application-approve-v1", "application_approved_v1")
	command(destination, "application-apply-v1", "application_applied_v1")
	command(source, "application-publish-v2", "application_published_v2")
	command(destination, "application-available-v2", "application_available_v2")
	command(destination, "application-stage-public-v2", "application_staged_public_v2")
	command(destination, "application-current-v1", "application_current_v1")

	command(destination, "stop", "stopped")
	if err := destination.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	setJoinSeed(destinationFolder, sourceSeed)
	destination = start(0, destinationFolder)
	marker(destination, "ready ")
	command(destination, "probe", "probe_passed")
	command(destination, "application-restored-v1", "application_restored_v1")
	command(destination, "application-current-v1", "application_current_v1")
	command(destination, "application-update-v2", "application_updated_v2")
	command(destination, "application-rollback-v1", "application_rolled_back_v1")
	command(source, "stop", "stopped")
	command(destination, "stop", "stopped")
	if err := source.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	if err := destination.wait(5 * time.Second); err != nil {
		t.Fatal(err)
	}
	t.Log("source publication became available through automatic Hive distribution; destination staged and activated only after local review")
}

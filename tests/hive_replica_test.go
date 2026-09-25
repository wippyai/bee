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
	testHiveSupervisorReplica(t, nil)
}

type hiveAgentArtifactScenario struct {
	destinationFolder string
	workspaceID       string
	artifactDigest    string
	encodedArtifact   string
	sourceProject     string
	sourceState       string
	sourceWorkspaceID string
	sourceVersion     string
}

// TestHiveSupervisorAgentSource publishes from the retained state whose managed
// agent authored, reviewed and applied the application. Unlike the retained
// artifact composition above, no artifact bytes are injected into a fresh
// source runtime.
func TestHiveSupervisorAgentSource(t *testing.T) {
	artifactPath := os.Getenv("BEE_AGENT_APP_HIVE_ARTIFACT")
	destinationFolder := os.Getenv("BEE_AGENT_APP_HIVE_DESTINATION")
	workspaceID := os.Getenv("BEE_AGENT_APP_HIVE_WORKSPACE")
	sourceProject := os.Getenv("BEE_AGENT_APP_HIVE_SOURCE_PROJECT")
	sourceState := os.Getenv("BEE_AGENT_APP_HIVE_SOURCE_STATE")
	sourceWorkspaceID := os.Getenv("BEE_AGENT_APP_HIVE_SOURCE_WORKSPACE")
	for name, value := range map[string]string{"artifact": artifactPath, "destination": destinationFolder,
		"destination workspace": workspaceID, "source project": sourceProject, "source state": sourceState,
		"source workspace": sourceWorkspaceID} {
		if value == "" {
			t.Skipf("set the continuous agent Hive %s", name)
		}
	}
	absolute := func(path string) string {
		value, err := filepath.Abs(path)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	artifactPath, destinationFolder = absolute(artifactPath), absolute(destinationFolder)
	sourceProject, sourceState = absolute(sourceProject), absolute(sourceState)
	if !lowerHex(workspaceID, 32) || !lowerHex(sourceWorkspaceID, 32) {
		t.Fatal("continuous agent Hive workspace identity is malformed")
	}
	for _, path := range []string{filepath.Join(destinationFolder, "src"), filepath.Join(sourceProject, "src")} {
		if info, err := os.Stat(path); err != nil || !info.IsDir() {
			t.Fatalf("continuous agent Hive project is unavailable: %s: %v", path, err)
		}
	}
	raw, err := os.ReadFile(artifactPath)
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Updated struct {
			ArtifactDigest string `json:"artifact_digest"`
		} `json:"updated"`
		PublishedVersion string `json:"published_version"`
	}
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	if !lowerHex(document.Updated.ArtifactDigest, 64) {
		t.Fatal("continuous agent artifact digest is malformed")
	}
	testHiveSupervisorReplica(t, &hiveAgentArtifactScenario{destinationFolder: destinationFolder,
		workspaceID: workspaceID, artifactDigest: document.Updated.ArtifactDigest,
		sourceProject: sourceProject, sourceState: sourceState, sourceWorkspaceID: sourceWorkspaceID,
		sourceVersion: document.PublishedVersion})
}

// TestHiveSupervisorAgentArtifact is intentionally opt-in. Its wrapper starts
// an ordinary destination desktop first, then this headless half carries only
// the retained Agent App v2 artifact across Hive and leaves that same desktop
// database for a normal desktop boot and UI proof.
func TestHiveSupervisorAgentArtifact(t *testing.T) {
	artifactPath := os.Getenv("BEE_AGENT_APP_HIVE_ARTIFACT")
	destinationFolder := os.Getenv("BEE_AGENT_APP_HIVE_DESTINATION")
	workspaceID := os.Getenv("BEE_AGENT_APP_HIVE_WORKSPACE")
	if artifactPath == "" || destinationFolder == "" || workspaceID == "" {
		t.Skip("set BEE_AGENT_APP_HIVE_ARTIFACT, BEE_AGENT_APP_HIVE_DESTINATION and BEE_AGENT_APP_HIVE_WORKSPACE for retained Agent App Hive acceptance")
	}
	artifactPath, err := filepath.Abs(artifactPath)
	if err != nil {
		t.Fatal(err)
	}
	destinationFolder, err = filepath.Abs(destinationFolder)
	if err != nil {
		t.Fatal(err)
	}
	if !lowerHex(workspaceID, 32) {
		t.Fatalf("destination desktop workspace ID is malformed: %q", workspaceID)
	}
	if info, statErr := os.Stat(filepath.Join(destinationFolder, "src")); statErr != nil || !info.IsDir() {
		t.Fatalf("pre-established destination desktop project is unavailable: %v", statErr)
	}
	raw, err := os.ReadFile(artifactPath)
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Updated struct {
			ArtifactDigest string `json:"artifact_digest"`
		} `json:"updated"`
		Entries json.RawMessage `json:"entries"`
	}
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatalf("decode retained agent artifact: %v", err)
	}
	if !lowerHex(document.Updated.ArtifactDigest, 64) {
		t.Fatalf("retained agent artifact has no updated.artifact_digest: %q", document.Updated.ArtifactDigest)
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(document.Entries, &entries); err != nil || len(entries) != 1 {
		t.Fatalf("retained agent artifact must expose exactly its updated v2 entry: %v (%d entries)", err, len(entries))
	}
	testHiveSupervisorReplica(t, &hiveAgentArtifactScenario{
		destinationFolder: destinationFolder,
		workspaceID:       workspaceID,
		artifactDigest:    document.Updated.ArtifactDigest,
		encodedArtifact:   base64.StdEncoding.EncodeToString(raw),
	})
}

func lowerHex(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func configureAgentArtifactFixture(folder string, scenario *hiveAgentArtifactScenario, source bool) error {
	path := filepath.Join(folder, "src", "replica_probe", "_index.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	const scenarioMarker = "data: {workspace_id: '', artifact_digest: '', source_node: '', source_workspace_id: '', source_version: ''}"
	sourceNode, sourceWorkspaceID := "", ""
	if scenario.sourceProject != "" {
		sourceNode, sourceWorkspaceID = "node-1", scenario.sourceWorkspaceID
	}
	scenarioData := fmt.Sprintf("data: {workspace_id: %s, artifact_digest: %s, source_node: '%s', source_workspace_id: '%s', source_version: '%s'}",
		scenario.workspaceID, scenario.artifactDigest, sourceNode, sourceWorkspaceID, scenario.sourceVersion)
	updated := strings.Replace(string(data), scenarioMarker, scenarioData, 1)
	if updated == string(data) {
		return fmt.Errorf("configure agent artifact scenario")
	}
	if source {
		const artifactMarker = "data: {encoded: ''}"
		artifactData := fmt.Sprintf("data: {encoded: %s}", scenario.encodedArtifact)
		next := strings.Replace(updated, artifactMarker, artifactData, 1)
		if next == updated {
			return fmt.Errorf("configure source agent artifact bytes")
		}
		updated = next
	}
	return os.WriteFile(path, []byte(updated), 0600)
}

func testHiveSupervisorReplica(t *testing.T, agent *hiveAgentArtifactScenario) {
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
	tlsRoot := root
	if agent != nil {
		// The destination desktop boots after this Go test has returned. Keep
		// its node identity configuration and TLS material in the retained
		// destination state so recovery runs as the same node with the source
		// offline, rather than silently becoming a new local-only node.
		tlsRoot = agent.destinationFolder
	}
	transportTLS := supervisorTLS(t, tlsRoot)
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
			"codex="+binary, "grok="+binary, "ANTHROPIC_API_KEY=fixture-only",
			"BEE_AGENT_APP_AGY="+binary, "BEE_AGENT_APP_HOME="+os.Getenv("HOME"))
	}
	moduleNames := []string{
		"application", "approvals", "credentials", "docs", "driver", "driver-agy",
		"driver-claude", "driver-codex", "driver-grok", "driver-muse", "gateway", "gov",
		"harness", "hive", "hub", "node", "persist", "placement", "placement-native",
		"resources", "sync", "threads",
	}
	type stagedNode struct{ project, state string }
	stage := func(i int, seed string) stagedNode {
		folder := filepath.Join(root, fmt.Sprintf("node-%d", i))
		project, state := folder, folder
		externalDestination := agent != nil && i == 0
		if externalDestination {
			project, state = agent.destinationFolder, agent.destinationFolder
			if info, err := os.Stat(filepath.Join(project, "src")); err != nil || !info.IsDir() {
				t.Fatalf("destination desktop project disappeared before Hive staging: %v", err)
			}
		} else if agent != nil && i == 1 && agent.sourceProject != "" {
			project, state = agent.sourceProject, agent.sourceState
		} else if err := os.CopyFS(filepath.Join(project, "src"), os.DirFS(filepath.Join(repository, "src"))); err != nil {
			t.Fatal(err)
		}
		// This acceptance owns the supervisor lifecycle and supplies the
		// enrolled peer list directly. The default local service stays
		// declared in the composed Hive module but never starts here; the
		// launch override below keeps it out of this deliberately explicit
		// composition. The real Hive sender still comes from the composed
		// module that the root Sync dependency injects into distribution.
		for _, name := range moduleNames {
			module := name
			if err := os.CopyFS(filepath.Join(project, "modules", module), os.DirFS(filepath.Join(repository, "modules", module))); err != nil {
				t.Fatal(err)
			}
		}
		if i == 0 && agent == nil {
			governancePath := filepath.Join(project, "src", "_index.yaml")
			governance, err := os.ReadFile(governancePath)
			if err != nil {
				t.Fatal(err)
			}
			oldProfiles := `    profiles: []
    workspace_applications:
      approval_policy: workspace-application-delivery`
			newProfiles := `    profiles:
    - workspace_id: workspace-node-0
      source_node: node-1
      source_workspace: shared/application
      component: private/bee-demo
      resolver: overlay
      overlay_owner: bee.replica_probe:activation_overlay
      approval_policy: local-install
      parameters: []
      allow:
        packages: [private/bee-demo]
        namespaces: [private.bee_demo]
        kinds: [function.lua]
        databases: []
        grants: []
        modules: []
    workspace_applications:
      approval_policy: workspace-application-delivery`
			updated := strings.Replace(string(governance), oldProfiles, newProfiles, 1)
			if updated == string(governance) {
				t.Fatal("stage destination activation profile")
			}
			if err := os.WriteFile(governancePath, []byte(updated), 0600); err != nil {
				t.Fatal(err)
			}

			approvalsPath := filepath.Join(project, "src", "_index.yaml")
			approvals, err := os.ReadFile(approvalsPath)
			if err != nil {
				t.Fatal(err)
			}
			oldApprovers := "- name: approver_policies\n  kind: registry.entry\n  meta:\n    type: bee.approval_policies\n    comment: Host-owned approver policies; a request names one, and only its approvers decide it\n  policies:\n  - name: workspace-application-delivery\n    approvers:\n    - definition_id: bee.inbox:app\n    max_ttl_ms: 600000"
			newApprovers := "- name: approver_policies\n  kind: registry.entry\n  meta:\n    type: bee.approval_policies\n    comment: Host-owned approver policies; a request names one, and only its approvers decide it\n  policies:\n  - name: workspace-application-delivery\n    approvers:\n    - definition_id: bee.inbox:app\n    max_ttl_ms: 600000\n  - name: local-install\n    approvers: [bee.replica_probe]\n    max_ttl_ms: 60000"
			updated = strings.Replace(string(approvals), oldApprovers, newApprovers, 1)
			if updated == string(approvals) {
				t.Fatal("stage destination approval profile")
			}
			if err := os.WriteFile(approvalsPath, []byte(updated), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if !(agent != nil && i == 1 && agent.sourceProject != "") {
			if err := os.CopyFS(filepath.Join(project, "src", "replica_probe"), os.DirFS(filepath.Join(repository, "tests/fixtures/hive_replica"))); err != nil {
				t.Fatal(err)
			}
		}
		if agent != nil && !(i == 1 && agent.sourceProject != "") {
			if err := configureAgentArtifactFixture(project, agent, i == 1 && agent.sourceProject == ""); err != nil {
				t.Fatal(err)
			}
		}
		lock := "directories:\n  modules: .wippy\n  src: ./src\nmodules:\n"
		for _, name := range moduleNames {
			component := name
			if name == "gov" {
				component = "governance"
			}
			lock += "- name: bee/" + component + "\n  version: 0.1.0-dev\n"
		}
		if err := os.WriteFile(filepath.Join(project, "wippy.lock"), []byte(lock), 0600); err != nil {
			t.Fatal(err)
		}
		projectConfig, err := os.ReadFile(filepath.Join(repository, "wippy.yaml"))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(project, "wippy.yaml"), projectConfig, 0600); err != nil {
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
				"raft":       map[string]any{"role": role, "bootstrap_expect": expected, "max_voters": 1, "max_standbys": 0, "data_dir": filepath.Join(state, "node-state")},
				"membership": map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "join_addrs": seed, "secret_key": secretString},
				"internode":  map[string]any{"bind_addr": "127.0.0.1", "bind_port": 0, "auto_port": true, "identity_key": keys[i], "trusted_peer_keys": trusted, "tls": transportTLS},
			},
		}
		replacements := map[string]string{}
		for _, name := range moduleNames {
			component := name
			if name == "gov" {
				component = "governance"
			}
			replacements["bee/"+component] = "./modules/" + name
		}
		config["workspace"] = map[string]any{"replacements": replacements}
		data, err := json.Marshal(config)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(project, ".wippy.yaml"), data, 0600); err != nil {
			t.Fatal(err)
		}
		lintArgs := []string{"lint", "--json"}
		if agent != nil {
			lintArgs = append(lintArgs, "--set", "registry.history_path="+filepath.Join(state, "registry.db"))
		}
		lint := exec.CommandContext(ctx, binary, lintArgs...)
		lint.Dir = project
		lint.Env = nodeEnvironment(state)
		if output, err := lint.CombinedOutput(); err != nil {
			t.Fatalf("node %d lint: %v\n%s", i, err, sanitizeDiagnostics(string(output), secretString, keys))
		}
		return stagedNode{project: project, state: state}
	}
	start := func(i int, node stagedNode) *procRunner {
		args := []string{"run", "--silent", "--override", "bee.hive_host:supervisor_service:lifecycle.auto_start=false", "hive-replica-probe"}
		if agent != nil {
			args = append(args, "--set", "registry.history_path="+filepath.Join(node.state, "registry.db"))
		}
		args = append(args, "--", fmt.Sprintf("node-%d", 1-i))
		if agent != nil && i == 1 && agent.sourceProject != "" {
			args = append(args, agent.workspaceID, agent.artifactDigest, agent.sourceWorkspaceID, agent.sourceVersion)
		}
		cmd := exec.CommandContext(ctx, binary, args...)
		cmd.Dir = node.project
		cmd.Env = append(nodeEnvironment(node.state), "GOMAXPROCS=2")
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

	destinationNode := stage(0, "")
	destination := start(0, destinationNode)
	seed := marker(destination, "ready ")
	source := start(1, stage(1, seed))
	sourceSeed := marker(source, "ready ")
	command(destination, "probe", "probe_passed")
	command(source, "probe", "probe_passed")
	if agent == nil || agent.sourceProject == "" {
		command(source, "replica-unmapped", "replica_unmapped")
		command(destination, "replica-read", "replica_exact")
		command(source, "replica-source-mismatch", "replica_source_mismatch")
		command(source, "replica-publish", "replica_published")
		command(destination, "replica-available", "replica_available")
	}
	if agent != nil {
		command(destination, "agent-artifact-absent", "agent_artifact_absent")
		command(source, "agent-artifact-publish", "agent_artifact_published")
		command(destination, "agent-artifact-available", "agent_artifact_available")
		command(destination, "agent-artifact-stage", "agent_artifact_staged")
		command(destination, "agent-artifact-apply", "agent_artifact_applied")
		// The normal desktop below owns the only visible client. Both headless
		// coordinators are gone before that boot; it receives only the durable
		// destination state, its configured admission and the applied overlay.
		command(source, "stop", "stopped")
		command(destination, "stop", "stopped")
		if err := source.wait(5 * time.Second); err != nil {
			t.Fatal(err)
		}
		if err := destination.wait(5 * time.Second); err != nil {
			t.Fatal(err)
		}
		if agent.sourceProject != "" {
			t.Log("locally applied Agent App was published by its authoring source, crossed Hive, and was applied through destination-local review and approval")
		} else {
			t.Log("retained Agent App v2 was recreated only on the source, published through Hive, and applied through destination-local review and approval")
		}
		return
	}

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
	setJoinSeed(destinationNode.project, sourceSeed)
	destination = start(0, destinationNode)
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

// SPDX-License-Identifier: MIT
//go:build hiveintegration

package service_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	supapi "github.com/wippyai/runtime/api/supervisor"
	"github.com/wippyai/runtime/api/topology"

	service "github.com/wippyai/bee/native/hive/service"
)

func defaultTestPolicies() []string {
	return []string{
		"bee:hive_supervisor_policy",
		"bee:hive_catalog_policy",
		"bee:hive_exposure_policy",
		"bee:hive_dispatch_policy",
		"bee.hive:names",
		"bee.hive:execute",
	}
}

type stageOptions struct {
	activationName   string
	extraData        string
	missingPolicy    string
	wrongKindTarget  string // "process", "host", "policy"
	omitMetadata     bool
	configuredNodes  []string
	injectAssertions bool
}

// stageTestDirectory sets up the isolated runtime source tree using current src/hive
// frozen at test entry, the production canonical encoder, and the minimal host fixture.
func stageTestDirectory(t *testing.T, opts stageOptions) string {
	t.Helper()
	root := t.TempDir()
	srcDir := filepath.Join(root, "src")
	repo := repositoryRoot(t)
	if err := os.MkdirAll(srcDir, 0700); err != nil {
		t.Fatal(err)
	}
	host, err := os.ReadFile(filepath.Join(repo, "tests/fixtures/hive_supervisor/host.manifest"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(srcDir, "_index.yaml"), host, 0600); err != nil {
		t.Fatal(err)
	}
	canonicalDir := filepath.Join(srcDir, "canonical")
	if err := os.Mkdir(canonicalDir, 0700); err != nil {
		t.Fatal(err)
	}
	canonical, err := os.ReadFile(filepath.Join(repo, "src/threads/records/canonical.lua"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(canonicalDir, "canonical.lua"), canonical, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(canonicalDir, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.threads.records\nentries:\n- name: canonical\n  kind: library.lua\n  source: file://canonical.lua\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// Only value interfaces enter this isolated fixture, never desktop processes or stores.
	for _, dependency := range []struct{ directory, source, manifest string }{
		{"application_arguments", "src/ui/application/arguments.lua", "version: '1.0'\nnamespace: bee.application\nentries:\n- name: arguments\n  kind: library.lua\n  source: file://source.lua\n"},
		{"application_protocol", "src/core/protocol/application.lua", "version: '1.0'\nnamespace: bee.protocol\nentries:\n- name: application\n  kind: library.lua\n  source: file://source.lua\n  imports:\n    arguments: bee.application:arguments\n"},
		{"retained_protocol", "src/core/launch/retained_protocol.lua", "version: '1.0'\nnamespace: bee.launch\nentries:\n- name: retained_protocol\n  kind: library.lua\n  source: file://source.lua\n  imports:\n    contract: bee.protocol:application\n"},
	} {
		directory := filepath.Join(srcDir, dependency.directory)
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		body, err := os.ReadFile(filepath.Join(repo, dependency.source))
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
	hiveDir := filepath.Join(srcDir, "hive")
	if err := os.CopyFS(hiveDir, os.DirFS(filepath.Join(repo, "src/hive"))); err != nil {
		t.Fatal(err)
	}

	if opts.missingPolicy != "" {
		hostFile := filepath.Join(srcDir, "_index.yaml")
		content, err := os.ReadFile(hostFile)
		if err != nil {
			t.Fatal(err)
		}
		modified := strings.Replace(string(content), "- name: hive_catalog_policy", "- name: removed_policy", 1)
		if err := os.WriteFile(hostFile, []byte(modified), 0600); err != nil {
			t.Fatal(err)
		}
	}

	if opts.wrongKindTarget == "process" {
		supFile := filepath.Join(hiveDir, "supervisor/_index.yaml")
		content, err := os.ReadFile(supFile)
		if err != nil {
			t.Fatal(err)
		}
		modified := strings.Replace(string(content), "kind: process.lua", "kind: library.lua", 1)
		if err := os.WriteFile(supFile, []byte(modified), 0600); err != nil {
			t.Fatal(err)
		}
	}

	if opts.wrongKindTarget == "host" {
		supHostFile := filepath.Join(hiveDir, "_index.yaml")
		content, err := os.ReadFile(supHostFile)
		if err != nil {
			t.Fatal(err)
		}
		anchor := "kind: process.host\n  host: {max_processes: 1, workers: 1}"
		replacement := "kind: security.policy\n  policy: {actions: [funcs.call], resources: ['*'], effect: allow}"
		modified := strings.Replace(string(content), anchor, replacement, 1)
		if err := os.WriteFile(supHostFile, []byte(modified), 0600); err != nil {
			t.Fatal(err)
		}
	}

	if opts.wrongKindTarget == "policy" {
		hostFile := filepath.Join(srcDir, "_index.yaml")
		content, err := os.ReadFile(hostFile)
		if err != nil {
			t.Fatal(err)
		}
		anchor := "- name: hive_catalog_policy\n  kind: security.policy"
		replacement := "- name: hive_catalog_policy\n  kind: process.lua"
		if !strings.Contains(string(content), anchor) {
			t.Fatal("policy kind replacement anchor not found")
		}
		modified := strings.Replace(string(content), anchor, replacement, 1)
		if err := os.WriteFile(hostFile, []byte(modified), 0600); err != nil {
			t.Fatal(err)
		}
	}

	actName := "activation"
	if opts.activationName != "" {
		actName = opts.activationName
	}

	var manifest string
	if opts.omitMetadata {
		// Missing metadata case: entry lacks meta.depends_on entirely
		manifest = fmt.Sprintf(`version: '1.0'
namespace: bee.hive
entries:
- name: names
  kind: security.policy
  policy:
    actions: [process.registry.register, process.registry.unregister, process.registry.register.eventual, process.registry.unregister.eventual]
    resources: [bee.hive.supervisor, 'bee.hive.supervisor/*']
    effect: allow
- name: execute
  kind: security.policy
  policy:
    actions: [funcs.call]
    resources: [bee.hive.supervisor:execute]
    effect: allow
- name: %s
  kind: bee.hive.activation
`, actName)
	} else {
		manifest = fmt.Sprintf(`version: '1.0'
namespace: bee.hive
entries:
- name: names
  kind: security.policy
  policy:
    actions: [process.registry.register, process.registry.unregister, process.registry.register.eventual, process.registry.unregister.eventual]
    resources: [bee.hive.supervisor, 'bee.hive.supervisor/*']
    effect: allow
- name: execute
  kind: security.policy
  policy:
    actions: [funcs.call]
    resources: [bee.hive.supervisor:execute]
    effect: allow
- name: %s
  kind: bee.hive.activation
  meta:
    depends_on: [bee.hive.supervisor:main, bee.hive:supervisor_host, bee.hive:names, bee.hive:execute, bee:hive_supervisor_policy, bee:hive_catalog_policy, bee:hive_exposure_policy, bee:hive_dispatch_policy]
`, actName)
	}

	if opts.extraData != "" {
		manifest += opts.extraData
	}

	probeDir := filepath.Join(srcDir, "probe")
	if err := os.MkdirAll(probeDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(probeDir, "_index.yaml"), []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}

	if opts.injectAssertions {
		// Strict, typed Lua security assertions verifying actor, right boundaries,
		// and unconditional typed comparison of exact host configured_nodes input.
		mainPath := filepath.Join(hiveDir, "supervisor/main.lua")
		mainSource, err := os.ReadFile(mainPath)
		if err != nil {
			t.Fatal(err)
		}

		expectedLen := len(opts.configuredNodes)
		assertions := fmt.Sprintf(`    local security = require("security")
    local actor = security.actor()
    assert(actor and actor:id() == "bee.hive.supervisor", "wrong service actor")
    assert(security.can("process.registry.register", "bee.hive.supervisor"), "missing own-name authority")
    assert(security.can("funcs.call", "bee.hive.supervisor:execute"), "missing dispatch authority")
    assert(not security.can("process.registry.register", "unrelated.name"), "foreign-name authority")
    assert(not security.can("process.host", "bee:workers"), "unexpected host authority")
    assert(not security.can("process.spawn", "bee.hive.supervisor:main"), "unexpected spawn authority")
    assert(not security.can("security.scope.create", "scope"), "unexpected scope authority")
    assert(not security.can("funcs.call", "unrelated:operation"), "unrelated function authority")
    assert(not security.can("db.get", "bee:workspace_db"), "unexpected database authority")
    local config = configuration :: {[string]: unknown}
    assert(type(config) == "table", "configuration must be a table")
    local nodes = config.configured_nodes :: {string}
    assert(type(nodes) == "table", "configured_nodes must be a table")
    assert(#nodes == %d, "configured_nodes length mismatch: expected %d")
`, expectedLen, expectedLen)

		for i, n := range opts.configuredNodes {
			assertions += fmt.Sprintf(`    assert(nodes[%d] == %q, "configured_nodes[%d] mismatch")
`, i+1, n, i+1)
		}

		anchor := "local function main(configuration: unknown)\n"
		if strings.Count(string(mainSource), anchor) != 1 {
			t.Fatal("supervisor startup assertion anchor changed")
		}
		observed := strings.Replace(string(mainSource), anchor, anchor+assertions+"\n", 1)
		if err := os.WriteFile(mainPath, []byte(observed), 0600); err != nil {
			t.Fatal(err)
		}

		manifestPath := filepath.Join(hiveDir, "supervisor/_index.yaml")
		sManifest, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Fatal(err)
		}
		modules := "modules: [process, channel, time, uuid, funcs, logger]"
		if strings.Count(string(sManifest), modules) != 1 {
			t.Fatal("supervisor module assertion anchor changed")
		}
		observedManifest := strings.Replace(string(sManifest), modules, "modules: [process, channel, time, uuid, funcs, logger, security]", 1)
		if err := os.WriteFile(manifestPath, []byte(observedManifest), 0600); err != nil {
			t.Fatal(err)
		}
	}

	// Write wippy.lock to enable strict linting
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  src: ./src\n"), 0600); err != nil {
		t.Fatal(err)
	}

	return root
}

func waitForSupervisorPID(t *testing.T, ctx context.Context, timeout time.Duration) pid.PID {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if p, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); ok {
			return p
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s registration", service.ActorID)
	return pid.PID{}
}

func waitForSupervisorUnregistered(t *testing.T, ctx context.Context, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, ok := topology.GetRegistry(ctx).Lookup(service.ActorID); !ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s unregistration", service.ActorID)
}

func waitForServiceStatus(t *testing.T, ctx context.Context, expected string, timeout time.Duration) supapi.ServiceState {
	t.Helper()
	svcInfo := supapi.GetServiceInfo(ctx)
	if svcInfo == nil {
		t.Fatal("service info provider not available in context")
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		state, err := svcInfo.GetState(registry.ParseID(service.ActivationID))
		if err == nil {
			if expected == supapi.StatusFailed {
				if state.Status == supapi.StatusFailed || state.Status == supapi.StatusExited {
					return state
				}
			} else if state.Status == expected {
				return state
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	state, _ := svcInfo.GetState(registry.ParseID(service.ActivationID))
	t.Fatalf("timed out waiting for service %s status %q (last: %s)", service.ActivationID, expected, state.Status)
	return supapi.ServiceState{}
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "src/hive/_index.yaml")); err != nil {
		t.Fatal(err)
	}
	return root
}

// Nonempty peer input requires native EVENTUAL naming. Use an isolated client-role
// mesh with no seed peers; this proves input delivery, not remote enrollment.
func inputMeshConfig(t *testing.T) boot.Config {
	t.Helper()
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	return boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": "input-review"}),
		boot.WithSection("cluster", map[string]any{
			"enabled": true, "name": "input-review", "raft.role": "client",
			"internode.identity_key":                   base64.StdEncoding.EncodeToString(key),
			"internode.trusted_peer_keys.input-review": base64.StdEncoding.EncodeToString(pub),
			"internode.bind_addr":                      "127.0.0.1", "internode.bind_port": 0, "internode.auto_port": true,
			"membership.bind_addr": "127.0.0.1", "membership.bind_port": 0,
			"membership.secret_key": base64.StdEncoding.EncodeToString(secret),
		}))
}

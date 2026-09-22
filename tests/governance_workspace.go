// SPDX-License-Identifier: MIT
// Verify durable governance authoring through two real runtime boots.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const defaultRuntime = ".wippy/bin/bee-wippy"

const syncIndex = `version: '1.0'
namespace: bee.sync
entries:
- name: definition
  kind: ns.definition
  module: sync
  readme: file://README.md
- name: bounds
  kind: library.lua
  source: file://bounds.lua
- name: canonical
  kind: library.lua
  source: file://canonical.lua
  modules: [json]
  imports:
    bounds: bee.sync:bounds
`

const recordsIndex = `version: '1.0'
namespace: bee.threads.records
entries:
- name: bounds
  kind: library.lua
  source: file://bounds.lua
`

// Keep this acceptance composition limited to the authoring boundary it boots.
// The production governance namespace also contains delivery and activation
// services whose host-selected dependencies deliberately are not present here.
const governanceIndex = `version: '1.0'
namespace: bee.governance
entries:
- name: workspace
  kind: library.lua
  source: file://workspace.lua
  modules: [hash]
  imports: {canonical: bee.sync:canonical}
- name: preflight
  kind: library.lua
  source: file://preflight.lua
  modules: [hash, json]
  imports: {canonical: bee.sync:canonical}
- name: target_db
  kind: ns.requirement
  default: bee.governance:db
  targets:
  - entry: bee.governance:database_ref
    path: .resource_ref
- name: database_ref
  kind: registry.entry
- name: environment
  kind: env.storage.os
  lifecycle: {auto_start: true}
- name: db_path
  kind: env.variable
  storage: bee.governance:environment
  variable: BEE_GOVERNANCE_DB
  default: .wippy/governance.db
  readonly: true
- name: db
  kind: db.sql.sqlite
  file: ${env:bee.governance:db_path}
  lifecycle: {auto_start: true}
- name: workspace_protocol
  kind: library.lua
  source: file://workspace_protocol.lua
  modules: [base64]
  imports: {bounds: bee.threads.records:bounds}
- name: overlay_call
  kind: function.lua
  source: file://workspace_method.lua
  method: handle
  modules: [funcs, security]
  imports: {protocol: bee.governance:workspace_protocol, guide: bee.governance.traits:guide, transaction: bee.persist:transaction, bounds: bee.threads.records:bounds}
  security: {policies: [bee.governance.security:overlay_facade_policy]}
`

const governanceBindingIndex = `version: '1.0'
namespace: bee.governance.binding
entries:
- name: workspace_backend_call
  kind: function.lua
  source: file://authoring.lua
  method: call
  modules: [security, system]
  imports:
    protocol: bee.governance:workspace_protocol
    staging: bee.governance.persist:staging
    resources: bee.governance.registry:staging_resources
    transaction: bee.persist:transaction
`

const governancePersistIndex = `version: '1.0'
namespace: bee.governance.persist
entries:
- name: staging
  kind: library.lua
  source: file://staging.lua
  modules: [sql, hash, base64]
  imports:
    database: bee.persist:database
    transaction: bee.persist:transaction
    migrations: bee.governance.migrations:schema
    protocol: bee.governance:workspace_protocol
    workspace: bee.governance:workspace
    bounds: bee.threads.records:bounds
`

const governanceMigrationsIndex = `version: '1.0'
namespace: bee.governance.migrations
entries:
- name: schema
  kind: library.lua
  source: file://schema.lua
`

const governanceRegistryIndex = `version: '1.0'
namespace: bee.governance.registry
entries:
- name: staging_resources
  kind: library.lua
  source: file://staging_resources.lua
  modules: [registry]
  imports: {bounds: bee.threads.records:bounds}
`

const governanceTraitsIndex = `version: '1.0'
namespace: bee.governance.traits
entries:
- name: guide
  kind: library.lua
  source: file://guide.lua
  modules: [json]
  imports: {preflight: bee.governance:preflight}
`

const governanceSecurityIndex = `version: '1.0'
namespace: bee.governance.security
entries:
- name: staging_policy
  kind: security.policy
  groups: [workspace_execution_scope]
  policy:
    actions: [db.get, registry.get, system.read]
    resources: [bee.governance:db, bee.governance:database_ref, node]
    effect: allow
- name: workspace_execution_policy
  kind: security.policy
  groups: [workspace_execution_scope]
  policy:
    actions: [bee.governance.workspace.execute]
    resources: [bee.governance.binding:workspace_backend_call]
    effect: allow
- name: overlay_facade_policy
  kind: security.policy.expr
  policy:
    expression: '(action == "funcs.security" && resource == "security") || (action == "security.policy_group.get" && resource == "bee.governance.security:workspace_execution_scope") || (action == "funcs.call" && resource == "bee.governance.binding:workspace_backend_call")'
    actions: [funcs.security, security.policy_group.get, funcs.call]
    resources: [security, bee.governance.security:workspace_execution_scope, bee.governance.binding:workspace_backend_call]
    effect: allow
`

func runCommand(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = append(os.Environ(), environment...)
	return command.CombinedOutput()
}

func copyTree(destination, source string) error {
	return os.CopyFS(destination, os.DirFS(source))
}

func copyFile(destination, source string) error {
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer to.Close()
	_, err = io.Copy(to, from)
	return err
}

func setup(root string) error {
	for _, source := range []struct{ name, path string }{
		{name: "gov", path: "src/gov"},
		{name: "sync", path: "modules/sync/src"},
		{name: "persist", path: "modules/persist/src"},
	} {
		if err := copyTree(filepath.Join(root, "src", source.name), source.path); err != nil {
			return fmt.Errorf("copy %s source: %w", source.name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "src", "gov", "_index.yaml"), []byte(governanceIndex), 0600); err != nil {
		return fmt.Errorf("write bounded governance composition: %w", err)
	}
	if err := os.RemoveAll(filepath.Join(root, "src", "gov", "service")); err != nil {
		return fmt.Errorf("remove unbound governance services: %w", err)
	}
	for path, index := range map[string]string{
		"binding/_index.yaml": governanceBindingIndex,
		"persist/_index.yaml": governancePersistIndex,
		"migrations/_index.yaml": governanceMigrationsIndex,
		"registry/_index.yaml": governanceRegistryIndex,
		"traits/_index.yaml": governanceTraitsIndex,
		"security/_index.yaml": governanceSecurityIndex,
	} {
		if err := os.WriteFile(filepath.Join(root, "src", "gov", path), []byte(index), 0600); err != nil {
			return fmt.Errorf("write bounded governance child composition: %w", err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "src", "sync", "_index.yaml"), []byte(syncIndex), 0600); err != nil {
		return fmt.Errorf("write bounded sync composition: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "src", "records"), 0700); err != nil {
		return fmt.Errorf("create records composition: %w", err)
	}
	if err := copyFile(filepath.Join(root, "src", "records", "bounds.lua"), "modules/threads/src/records/bounds.lua"); err != nil {
		return fmt.Errorf("copy records bounds: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "records", "_index.yaml"), []byte(recordsIndex), 0600); err != nil {
		return fmt.Errorf("write records composition: %w", err)
	}
	if err := copyTree(filepath.Join(root, "src", "governance_workspace_probe"), "tests/fixtures/governance_workspace"); err != nil {
		return fmt.Errorf("copy governance fixture: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write runtime lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return fmt.Errorf("write bounded shutdown config: %w", err)
	}
	return nil
}

func boot(runtime, root, phase string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	database := filepath.Join(root, "governance.db")
	output, err := runCommand(ctx, root, runtime, []string{
		"BEE_GOVERNANCE_DB=" + database,
		"GOMAXPROCS=2",
	}, "run", "--verbose", "--host", "bee.governance_workspace_probe:workers", "--", "governance-workspace-probe", phase)
	marker := "GOVERNANCE_WORKSPACE_" + strings.ToUpper(phase) + "_BOOT_PASS"
	if err != nil {
		return fmt.Errorf("%s boot: %w\n%s", phase, err, output)
	}
	if !strings.Contains(string(output), marker) {
		return fmt.Errorf("%s boot omitted %s\n%s", phase, marker, output)
	}
	fmt.Println(marker)
	return nil
}

func sqlite(root, query string) (string, error) {
	output, err := exec.Command("sqlite3", "-batch", "-noheader", filepath.Join(root, "governance.db"), query).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("inspect disposable governance database: %w\n%s", err, output)
	}
	return strings.TrimSpace(string(output)), nil
}

func migrationLedger(root string) (string, error) {
	ledger, err := sqlite(root, "SELECT id || '|' || name || '|' || checksum || '|' || applied_at FROM bee_governance_migrations ORDER BY id;")
	if err != nil {
		return "", err
	}
	expected := []string{"governance_workspace_staging", "governance_received_plans",
		"governance_plan_approval_proposal", "governance_plan_approval_incarnation",
		"governance_activation_intents", "governance_component_slots", "governance_activation_migrations",
		"governance_activation_application_admission"}
	rows := strings.Split(ledger, "\n")
	if len(rows) != len(expected) {
		return "", fmt.Errorf("unexpected governance migration ledger: %q", ledger)
	}
	for index, row := range rows {
		parts := strings.Split(row, "|")
		if len(parts) != 4 || parts[0] != fmt.Sprint(index+1) || parts[1] != expected[index] || len(parts[2]) != 64 || parts[3] == "" {
			return "", fmt.Errorf("unexpected governance migration ledger: %q", ledger)
		}
	}
	return ledger, nil
}

func run() error {
	runtimeFlag := flag.String("runtime", defaultRuntime, "Wippy runtime to verify")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return fmt.Errorf("resolve runtime: %w", err)
	}
	if info, err := os.Stat(runtime); err != nil || info.IsDir() {
		return fmt.Errorf("candidate runtime %q is unavailable", runtime)
	}
	root, err := os.MkdirTemp("", "bee-governance-workspace-")
	if err != nil {
		return fmt.Errorf("create disposable workspace: %w", err)
	}
	defer os.RemoveAll(root)
	if err := setup(root); err != nil {
		return err
	}

	lintContext, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	lint, err := runCommand(lintContext, root, runtime, nil, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict fixture lint: %w\n%s", err, lint)
	}

	if err := boot(runtime, root, "first"); err != nil {
		return err
	}
	before, err := migrationLedger(root)
	if err != nil {
		return err
	}
	if err := boot(runtime, root, "second"); err != nil {
		return err
	}
	after, err := migrationLedger(root)
	if err != nil {
		return err
	}
	if after != before {
		return fmt.Errorf("governance migration ledger changed across restart: %q -> %q", before, after)
	}
	content, err := sqlite(root, "SELECT content_base64 FROM bee_governance_snapshot_files ORDER BY path;")
	if err != nil {
		return err
	}
	if content != "AP9hc3NldA==" {
		return fmt.Errorf("frozen binary content changed: %q", content)
	}
	receipts, err := sqlite(root, "SELECT COUNT(*) FROM bee_governance_receipts;")
	if err != nil {
		return err
	}
	if receipts != "4" {
		return fmt.Errorf("receipt replay changed durable receipt count: %q", receipts)
	}
	fmt.Println("Governance authoring: two actual boots retained frozen binary bytes, exact receipts and author denial with an unchanged migration ledger; caller database, scope creation and private execution stayed denied")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// SPDX-License-Identifier: MIT
// Behavioral acceptance for durable saved agent profiles across real runtime boots.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const savedProfilesRuntime = ".wippy/bin/bee-wippy"

const savedProfilesRootIndex = `version: '1.0'
namespace: bee
entries:
- name: dependency_persist
  kind: ns.dependency
  component: bee/persist
  version: 0.1.0-dev
- name: dependency_sync
  kind: ns.dependency
  component: bee/sync
  version: 0.1.0-dev
  parameters:
  - name: target_sender
    value: bee:sync_sender
  - name: target_exports
    value: bee:sync_exports
- name: workers
  kind: process.host
  host: {workers: 2, max_processes: 8}
  lifecycle: {auto_start: true}
- name: sync_exports
  kind: registry.entry
  data: {exports: []}
- name: sync_sender
  kind: library.lua
  source: file://sync_sender.lua
  imports: {transaction: bee.persist:transaction, version: bee.sync:version}
`

const savedProfilesSecurityHarnessIndex = `version: '1.0'
namespace: bee.security.harness
entries:
- name: profile_store_policy
  kind: security.policy
  policy:
    actions: [db.get, registry.get, system.read]
    resources: [bee.node:db, bee.harness.profiles:database_ref, node]
    effect: allow
`

const savedProfilesSyncSender = `local transaction = require("transaction")
local version = require("version")
return {send = function(_: string, _: version.Descriptor, _: string, _: {timeout: string?, source_cursor: integer}): transaction.Result return transaction.failure("UNAVAILABLE", "saved profile fixture does not distribute replicas") end}
`

const savedProfilesHarnessIndex = `version: '1.0'
namespace: bee.harness
entries:
- name: definition
  kind: ns.definition
  module: harness
  readme: file://README.md
  meta:
    title: Bee harness
    comment: Execution contracts and the pinned discovery of admitted driver bindings; carriers arrive with launch admission
`

const savedProfilesNodeRootIndex = `version: '1.0'
namespace: bee.node
entries:
- name: definition
  kind: ns.definition
  module: node
  readme: file://README.md
- name: target_db
  kind: ns.requirement
  default: bee.node:db
  targets:
  - entry: bee.node:database_ref
    path: .resource_ref
- name: database_ref
  kind: registry.entry
  meta: {type: bee.resource_ref}
- name: environment
  kind: env.storage.os
  lifecycle: {auto_start: true}
- name: db_path
  kind: env.variable
  storage: bee.node:environment
  variable: BEE_NODE_DB
  default: .wippy/node.db
  readonly: true
- name: db
  kind: db.sql.sqlite
  file: ${env:bee.node:db_path}
  lifecycle: {auto_start: true}
`

const savedProfilesRecordsIndex = `version: '1.0'
namespace: bee.threads.records
entries:
- name: bounds
  kind: library.lua
  source: file://bounds.lua
- name: canonical
  kind: library.lua
  source: file://canonical.lua
  modules: [json]
`

func savedProfilesRunCommand(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = savedProfilesCommandEnvironment(environment)
	return command.CombinedOutput()
}

func savedProfilesCommandEnvironment(overrides []string) []string {
	replaced := make(map[string]struct{}, len(overrides))
	for _, value := range overrides {
		if key, _, ok := strings.Cut(value, "="); ok {
			replaced[key] = struct{}{}
		}
	}
	environment := make([]string, 0, len(os.Environ())+len(overrides))
	for _, value := range os.Environ() {
		key, _, ok := strings.Cut(value, "=")
		if !ok {
			continue
		}
		// A source acceptance must never open a caller's workspace or any
		// inherited subsystem database. The staged composition owns only node.db.
		if strings.HasPrefix(key, "BEE_") && strings.HasSuffix(key, "_DB") {
			continue
		}
		if _, replace := replaced[key]; !replace {
			environment = append(environment, value)
		}
	}
	return append(environment, overrides...)
}

func savedProfilesCopyTree(destination, source string) error {
	if err := os.MkdirAll(destination, 0700); err != nil {
		return err
	}
	return os.CopyFS(destination, os.DirFS(source))
}

func savedProfilesCopyFile(destination, source string) error {
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	to, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer to.Close()
	_, err = io.Copy(to, from)
	return err
}

func savedProfilesWrite(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0600)
}

func savedProfilesSetup(root, source string) error {
	if err := savedProfilesWrite(filepath.Join(root, "src", "_index.yaml"), savedProfilesRootIndex); err != nil {
		return err
	}
	if err := savedProfilesWrite(filepath.Join(root, "src", "security", "harness", "_index.yaml"), savedProfilesSecurityHarnessIndex); err != nil {
		return fmt.Errorf("write profile storage policy: %w", err)
	}
	if err := savedProfilesWrite(filepath.Join(root, "src", "harness", "_index.yaml"), savedProfilesHarnessIndex); err != nil {
		return fmt.Errorf("write harness index: %w", err)
	}
	if err := savedProfilesCopyFile(filepath.Join(root, "src", "harness", "README.md"), filepath.Join(source, "modules", "harness", "src", "README.md")); err != nil {
		return fmt.Errorf("copy harness README: %w", err)
	}
	if err := savedProfilesCopyTree(filepath.Join(root, "src", "harness", "profiles"), filepath.Join(source, "modules", "harness", "src", "profiles")); err != nil {
		return fmt.Errorf("copy profiles source: %w", err)
	}
	if err := savedProfilesCopyTree(filepath.Join(root, "modules", "sync"), filepath.Join(source, "modules", "sync")); err != nil {
		return fmt.Errorf("copy sync module: %w", err)
	}
	if err := savedProfilesCopyTree(filepath.Join(root, "modules", "persist"), filepath.Join(source, "modules", "persist")); err != nil {
		return fmt.Errorf("copy persist module: %w", err)
	}
	if err := savedProfilesWrite(filepath.Join(root, "src", "sync_sender.lua"), savedProfilesSyncSender); err != nil {
		return err
	}
	if err := savedProfilesCopyFile(filepath.Join(root, "src", "node", "README.md"), filepath.Join(source, "modules", "node", "src", "README.md")); err != nil {
		return fmt.Errorf("copy node README: %w", err)
	}
	if err := savedProfilesWrite(filepath.Join(root, "src", "node", "_index.yaml"), savedProfilesNodeRootIndex); err != nil {
		return err
	}
	if err := savedProfilesCopyFile(filepath.Join(root, "src", "threads", "records", "bounds.lua"), filepath.Join(source, "modules", "threads", "src", "records", "bounds.lua")); err != nil {
		return err
	}
	if err := savedProfilesCopyFile(filepath.Join(root, "src", "threads", "records", "canonical.lua"), filepath.Join(source, "modules", "threads", "src", "records", "canonical.lua")); err != nil {
		return err
	}
	if err := savedProfilesWrite(filepath.Join(root, "src", "threads", "records", "_index.yaml"), savedProfilesRecordsIndex); err != nil {
		return err
	}
	if err := savedProfilesCopyTree(filepath.Join(root, "src", "saved_profiles_probe"), filepath.Join(source, "tests", "fixtures", "saved_profiles")); err != nil {
		return fmt.Errorf("copy saved profile fixture: %w", err)
	}
	if err := savedProfilesWrite(filepath.Join(root, "wippy.lock"), "directories:\n  modules: .wippy\n  src: ./src\nmodules:\n- name: bee/persist\n  version: 0.1.0-dev\n- name: bee/sync\n  version: 0.1.0-dev\n"); err != nil {
		return err
	}
	if err := savedProfilesWrite(filepath.Join(root, ".wippy.yaml"), "version: '1.0'\nshutdown:\n  timeout: 2s\nworkspace:\n  replacements:\n    bee/persist: ./modules/persist\n    bee/sync: ./modules/sync\n"); err != nil {
		return err
	}
	return nil
}

func savedProfilesBoot(runtime, root, phase, expectedNode string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	args := []string{"run", "--verbose", "--host", "bee.saved_profiles_probe:workers", "--", "saved-profiles-probe", phase}
	if expectedNode != "" {
		args = append(args, expectedNode)
	}
	output, err := savedProfilesRunCommand(ctx, root, runtime, []string{
		"BEE_NODE_DB=" + filepath.Join(root, "node.db"),
		"GOMAXPROCS=2",
	}, args...)
	if strings.Contains(strings.ToLower(string(output)), "service failed") {
		return string(output), fmt.Errorf("runtime reported a service failure")
	}
	return string(output), err
}

func savedProfilesRun(runtime, source string) error {
	root, err := os.MkdirTemp("", "bee-saved-profiles-")
	if err != nil {
		return fmt.Errorf("create disposable workspace: %w", err)
	}
	defer os.RemoveAll(root)
	if err := savedProfilesSetup(root, source); err != nil {
		return err
	}
	lintContext, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	lint, err := savedProfilesRunCommand(lintContext, root, runtime, nil, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict fixture lint: %w\n%s", err, lint)
	}
	first, err := savedProfilesBoot(runtime, root, "first", "")
	if err != nil {
		return fmt.Errorf("first saved profile boot: %w\n%s", err, first)
	}
	nodePattern := regexp.MustCompile(`SAVED_PROFILE_FIRST_BOOT_PASS node=([[:alnum:]_.-]+)`)
	match := nodePattern.FindStringSubmatch(first)
	if len(match) != 2 {
		return fmt.Errorf("first boot omitted native identity marker\n%s", first)
	}
	node := match[1]
	fmt.Println("SAVED_PROFILE_FIRST_BOOT_PASS")
	second, err := savedProfilesBoot(runtime, root, "second", node)
	if err != nil {
		return fmt.Errorf("second saved profile boot: %w\n%s", err, second)
	}
	marker := "SAVED_PROFILE_SECOND_BOOT_PASS node=" + node + " actor=profile-reader"
	if !strings.Contains(second, marker) {
		return fmt.Errorf("second boot omitted %q\n%s", marker, second)
	}
	fmt.Println("SAVED_PROFILE_SECOND_BOOT_PASS")
	fmt.Println("Saved profiles: two real process boots retained value/revision and tombstone under stable native node identity; a different authenticated actor read the value and historical receipt replay did not resurrect deletion")
	return nil
}

func main() {
	runtimeFlag := flag.String("runtime", savedProfilesRuntime, "Wippy runtime to verify")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	source, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if info, err := os.Stat(runtime); err != nil || info.IsDir() {
		fmt.Fprintf(os.Stderr, "candidate runtime %q is unavailable\n", runtime)
		os.Exit(1)
	}
	if err := savedProfilesRun(runtime, source); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

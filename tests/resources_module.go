// SPDX-License-Identifier: MIT
// Behavioral acceptance for the independently staged resources and
// credentials module closures.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

const resourcesModuleRuntime = ".wippy/bin/bee-wippy"

type resourcesModuleIndex struct {
	Version   string                   `yaml:"version"`
	Namespace string                   `yaml:"namespace"`
	Entries   []map[string]interface{} `yaml:"entries"`
}

const resourcesProbe = `
local funcs = require("funcs")
local security = require("security")
local ACTOR = "bee.test.rmod"
local WORKSPACE = "module-ws"
local function call(scope: security.Scope?, method: string, request: {[string]: unknown}): {[string]: unknown}
    local executor = funcs.new()
    if scope then
        local scoped, scope_error = executor:with_scope(scope)
        assert(scoped, "with_scope: " .. tostring(scope_error))
        executor = scoped
    end
    local reply, err = executor:call("bee.resources.binding:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    return reply :: {[string]: unknown}
end
local function ok(reply: {[string]: unknown}, method: string): {[string]: unknown}
    assert(reply.ok == true, method .. " failed: " .. tostring(type(reply.error) == "table" and (reply.error :: {[string]: unknown}).message))
    return reply.value :: {[string]: unknown}
end
local function main(phase: string?)
    if phase == "changed" then
        local listed = ok(call(nil, "list", {workspace_id = WORKSPACE}), "list")
        local grants = listed.grants :: {{[string]: unknown}}
        assert(#grants == 1, "changed-root probe lost its original grant")
        local refused = call(nil, "resolve", {grant_id = tostring(grants[1].grant_id), subject = ACTOR, audience = ACTOR})
        assert(refused.ok == false and (refused.error :: {[string]: unknown}).code == "CONFLICT", "changed root did not fence the grant")
        return
    end
    ok(call(nil, "associate", {workspace_id = WORKSPACE, name = "root", root_ref = "bee.placement.native:root", subpath = "", allowed_access = "write"}), "associate")
    local granted = ok(call(nil, "grant", {workspace_id = WORKSPACE, name = "root", access = "read", purpose = "project", audience = ACTOR, idempotency_key = "k"}), "grant")
    local grant_id = tostring(granted.grant_id)
    ok(call(nil, "resolve", {grant_id = grant_id, subject = ACTOR, audience = ACTOR}), "resolve")
    -- The resource methods carry their production function scopes. A root
    -- backed by an unrelated environment variable must remain inaccessible
    -- even though this probe's caller has a broad test scope.
    local unrelated = call(nil, "associate", {workspace_id = WORKSPACE, name = "unrelated", root_ref = "bee.placement.native:unrelated_env_root", subpath = "", allowed_access = "write", expected_revision = 0})
    assert(unrelated.ok == false and (unrelated.error :: {[string]: unknown}).code == "INVALID", "unrelated environment variable was readable")
    -- An actor without the resolve policy cannot resolve a grant.
    local denied = call(security.new_scope({}), "resolve", {grant_id = grant_id, subject = ACTOR, audience = ACTOR})
    assert(denied.ok == false and (denied.error :: {[string]: unknown}).code == "DENIED", "unauthorized resolve was not denied")
end
return {main = main}
`

const credentialsProbe = `
local funcs = require("funcs")
local security = require("security")
local json = require("json")
local ACTOR = "bee.test.cmod"
local WORKSPACE = "module-ws"
local SENTINEL = "module-secret-9c2e"
local DIGEST = string.rep("a", 64)
local function call(scope: security.Scope?, method: string, request: {[string]: unknown}): {[string]: unknown}
    local executor = funcs.new()
    if scope then
        local scoped, scope_error = executor:with_scope(scope)
        assert(scoped, "with_scope: " .. tostring(scope_error))
        executor = scoped
    end
    local reply, err = executor:call("bee.credentials.binding:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    return reply :: {[string]: unknown}
end
local function ok(reply: {[string]: unknown}, method: string): {[string]: unknown}
    assert(reply.ok == true, method .. " failed: " .. tostring(type(reply.error) == "table" and (reply.error :: {[string]: unknown}).message))
    return reply.value :: {[string]: unknown}
end
local function main()
    local defined = ok(call(nil, "define", {workspace_id = WORKSPACE, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = "bee:module_secret"}}), "define")
    assert(tostring(defined.destination) == "ANTHROPIC_API_KEY", "unexpected destination")
    local projection = ok(call(nil, "issue_projection", {workspace_id = WORKSPACE, name = "anthropic", audience = ACTOR, attempt_id = "attempt-1",
        profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "issue-1"}), "issue_projection")
    assert(tostring(projection.materializer) == "bee:module_materializer", "projection did not record the host-selected materializer")
    local projection_id = tostring(projection.projection_id)
    local materialized = ok(call(nil, "materialize", {projection_id = projection_id, subject = ACTOR, audience = ACTOR, attempt_id = "attempt-1", generation_key = "g1"}), "materialize")
    assert(tostring(materialized.value) == SENTINEL, "materializer did not receive the secret")
    -- An actor without the issue policy cannot take a projection.
    local denied = call(security.new_scope({}), "issue_projection", {workspace_id = WORKSPACE, name = "anthropic", audience = ACTOR, attempt_id = "attempt-2",
        profile_id = "batch", profile_digest = DIGEST, binding_digest = DIGEST, launch_policy_digest = DIGEST, idempotency_key = "issue-2"})
    assert(denied.ok == false and (denied.error :: {[string]: unknown}).code == "DENIED", "unauthorized issue was not denied")
    -- A manager listing carries no secret bytes.
    local listed = ok(call(nil, "list", {workspace_id = WORKSPACE}), "list")
    assert(tostring(json.encode(listed)):find(SENTINEL, 1, true) == nil, "the secret leaked into a listing")
end
return {main = main}
`

var resourcesModuleProbeActions = []string{
	"funcs.call", "funcs.security", "security.scope.create", "registry.get",
	"bee.resources.manage", "bee.resources.grant", "bee.resources.resolve",
	"bee.credentials.manage", "bee.credentials.issue", "bee.credentials.materialize",
}

var resourcesModuleForbidden = []string{
	"bee.desktop", "bee.terminal", "bee.harness", "bee.harness.catalog", "bee.harness.carrier",
	"bee.harness.launch", "bee.harness.permission", "bee.hive", "bee.hive.supervisor", "bee.hive.telemetry",
	"bee.hive.desktop", "bee.session", "bee.applications", "bee.client", "bee.launch", "bee.driver",
}

func resourcesModuleCommandEnvironment(overrides []string) []string {
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
		if _, replace := replaced[key]; !replace {
			environment = append(environment, value)
		}
	}
	return append(environment, overrides...)
}

func resourcesModuleRunCommand(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = resourcesModuleCommandEnvironment(environment)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil || command.Process.Pid <= 0 {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 3 * time.Second
	return command.CombinedOutput()
}

func resourcesModuleRun(runtime, directory string, environment []string, expectedSuccess bool, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	output, err := resourcesModuleRunCommand(ctx, directory, runtime, environment, args...)
	success := err == nil
	if success != expectedSuccess {
		return string(output), fmt.Errorf("%v had success=%t, expected %t: %w\n%s", args, success, expectedSuccess, err, output)
	}
	return string(output), nil
}

func resourcesModuleWrite(folder, relative string, document interface{}) error {
	path := filepath.Join(folder, relative)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(path), err)
	}
	data, err := yaml.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode %s: %w", path, err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

func resourcesModuleBase(folder string, resources bool, credentials bool) error {
	modules := "    - name: bee/persist\n      version: 0.1.0-dev\n    - name: bee/threads\n      version: 0.1.0-dev\n"
	replacements := "    bee/persist: ./modules/persist\n    bee/threads: ./modules/threads\n"
	if resources {
		modules += "    - name: bee/resources\n      version: 0.1.0-dev\n"
		replacements += "    bee/resources: ./modules/resources\n"
	}
	if credentials {
		modules += "    - name: bee/credentials\n      version: 0.1.0-dev\n"
		replacements += "    bee/credentials: ./modules/credentials\n"
	}
	if err := os.WriteFile(filepath.Join(folder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\nmodules:\n"+modules), 0600); err != nil {
		return fmt.Errorf("write wippy.lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(folder, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\nworkspace:\n  replacements:\n"+replacements), 0600); err != nil {
		return fmt.Errorf("write .wippy.yaml: %w", err)
	}
	return nil
}

func resourcesModuleNamed(root, index, name string) (map[string]interface{}, error) {
	data, err := os.ReadFile(filepath.Join(root, "src", filepath.FromSlash(index), "_index.yaml"))
	if err != nil {
		return nil, fmt.Errorf("read source index: %w", err)
	}
	var document resourcesModuleIndex
	if err := yaml.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("decode source index: %w", err)
	}
	for _, entry := range document.Entries {
		if entryName, _ := entry["name"].(string); entryName == name {
			return entry, nil
		}
	}
	return nil, fmt.Errorf("source index has no entry %q", name)
}

func resourcesModuleCopyDir(destination, source string) error {
	if err := os.MkdirAll(destination, 0700); err != nil {
		return fmt.Errorf("create %s: %w", destination, err)
	}
	if err := os.CopyFS(destination, os.DirFS(source)); err != nil {
		return fmt.Errorf("copy %s to %s: %w", source, destination, err)
	}
	return nil
}

func resourcesModuleProbeIndex(namespace, command, actor string, modules []string) resourcesModuleIndex {
	return resourcesModuleIndex{
		Version: "1.0", Namespace: namespace,
		Entries: []map[string]interface{}{
			{"name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main", "modules": modules,
				"meta":     map[string]interface{}{"command": map[string]interface{}{"name": command, "security": map[string]interface{}{"actor": map[string]interface{}{"id": actor}}}},
				"security": map[string]interface{}{"policies": []string{namespace + ":policy"}}},
			{"name": "policy", "kind": "security.policy", "policy": map[string]interface{}{"actions": resourcesModuleProbeActions, "resources": "*", "effect": "allow"}},
		},
	}
}

func resourcesModuleStageResources(root, folder string, dropRoots bool) error {
	for _, name := range []string{"resources", "persist", "threads"} {
		if err := resourcesModuleCopyDir(filepath.Join(folder, "modules", name), filepath.Join(root, "modules", name)); err != nil {
			return err
		}
	}
	// This standalone probe supplies its own root composition and policies.
	if err := resourcesModuleBase(folder, true, false); err != nil {
		return err
	}
	resourcePolicyNames := []string{"resource_store_policy", "resource_environment_policy", "resource_manage_policy", "resource_grant_policy", "resource_resolve_policy"}
	hostEntries := make([]map[string]interface{}, 0, len(resourcePolicyNames)+1)
	for _, name := range resourcePolicyNames {
		entry, err := resourcesModuleNamed(root, "security/resources", name)
		if err != nil {
			return err
		}
		hostEntries = append(hostEntries, entry)
	}
	hostEntries = append(hostEntries, map[string]interface{}{"name": "terminal", "kind": "terminal.host", "hide_logs": true, "lifecycle": map[string]interface{}{"auto_start": true}})
	if !dropRoots {
		hostEntries = append(hostEntries, map[string]interface{}{"name": "resource_roots", "kind": "registry.entry", "meta": map[string]interface{}{"type": "bee.resource_roots"}, "data": map[string]interface{}{"roots": []map[string]interface{}{{"root_ref": "bee.placement.native:root", "access": "write"}, {"root_ref": "bee.placement.native:unrelated_env_root", "access": "write"}}}})
		if err := resourcesModuleWrite(folder, filepath.Join("src", "placement", "_index.yaml"), resourcesModuleIndex{
			Version: "1.0", Namespace: "bee.placement.native", Entries: []map[string]interface{}{
				{"name": "environment", "kind": "env.storage.os", "lifecycle": map[string]interface{}{"auto_start": true}},
				{"name": "root_path", "kind": "env.variable", "storage": "bee.placement.native:environment", "variable": "BEE_PLACEMENT_ROOT", "default": ".wippy/placement", "readonly": true},
				{"name": "unrelated_secret_path", "kind": "env.variable", "storage": "bee.placement.native:environment", "variable": "BEE_UNRELATED_SECRET_PATH", "default": ".wippy/unrelated-secret", "readonly": true},
				{"name": "root", "kind": "fs.directory", "directory": "${env:bee.placement.native:root_path}", "auto_init": true, "mode": "0700"},
				{"name": "unrelated_env_root", "kind": "fs.directory", "directory": "${env:bee.placement.native:unrelated_secret_path}", "auto_init": true},
			},
		}); err != nil {
			return err
		}
	}
	if err := resourcesModuleWrite(folder, filepath.Join("src", "host", "_index.yaml"), resourcesModuleIndex{Version: "1.0", Namespace: "bee", Entries: hostEntries}); err != nil {
		return err
	}
	if err := resourcesModuleWrite(folder, filepath.Join("src", "probe", "_index.yaml"), resourcesModuleProbeIndex("bee.res_probe", "res-probe", "bee.test.rmod", []string{"funcs", "security"})); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(folder, "src", "probe", "main.lua"), []byte(resourcesProbe), 0600); err != nil {
		return fmt.Errorf("write resources probe: %w", err)
	}
	return nil
}

func resourcesModuleStageCredentials(root, folder string, dropSources bool) error {
	for _, name := range []string{"credentials", "persist", "threads"} {
		if err := resourcesModuleCopyDir(filepath.Join(folder, "modules", name), filepath.Join(root, "modules", name)); err != nil {
			return err
		}
	}
	// This standalone probe supplies its own host bindings.
	if err := resourcesModuleBase(folder, false, true); err != nil {
		return err
	}
	policyNames := []string{"credential_store_policy", "credential_file_policy", "credential_manage_policy", "credential_issue_policy", "credential_materialize_policy"}
	hostEntries := make([]map[string]interface{}, 0, len(policyNames)+3)
	for _, name := range policyNames {
		entry, err := resourcesModuleNamed(root, "security/credentials", name)
		if err != nil {
			return err
		}
		hostEntries = append(hostEntries, entry)
	}
	// The host selects the placement binding recorded on projection receipts
	// without admitting placement execution into this closure.
	hostEntries = append(hostEntries,
		map[string]interface{}{"name": "module_storage", "kind": "env.storage.memory"},
		map[string]interface{}{"name": "module_secret", "kind": "env.variable", "storage": "bee:module_storage", "variable": "BEE_MODULE_SECRET", "default": "module-secret-9c2e"},
		map[string]interface{}{"name": "module_materializer", "kind": "registry.entry", "meta": map[string]interface{}{"comment": "Placement binding recorded on this closure's projections"}},
		map[string]interface{}{"name": "dependency_credentials", "kind": "ns.dependency", "component": "bee/credentials", "version": "0.1.0-dev",
			"parameters": []map[string]interface{}{{"name": "target_materializer", "value": "bee:module_materializer"}}},
	)
	// credential_sources is host wiring owned by the app root.
	sources, err := resourcesModuleNamed(root, "", "credential_sources")
	if err != nil {
		return err
	}
	if !dropSources {
		sources = resourcesModuleCloneEntry(sources)
		sources["data"] = map[string]interface{}{
			"formats": map[string]string{"claude": "bee:module_credential_format"},
			"sources": []map[string]interface{}{{"ref": "bee:module_secret", "workspace_id": "*", "audience": "bee.test.cmod", "provider": "claude", "projection_kinds": []string{"environment"}}},
		}
		hostEntries = append(hostEntries, map[string]interface{}{
			"name": "module_credential_format", "kind": "registry.entry",
			"meta": map[string]interface{}{"type": "bee.credential_format"},
			"data": map[string]interface{}{"schema_revision": "bee.credential-format@1", "environment_destination": "ANTHROPIC_API_KEY"},
		})
	}
	hostEntries = append(hostEntries, sources, map[string]interface{}{"name": "terminal", "kind": "terminal.host", "hide_logs": true, "lifecycle": map[string]interface{}{"auto_start": true}})
	if err := resourcesModuleWrite(folder, filepath.Join("src", "host", "_index.yaml"), resourcesModuleIndex{Version: "1.0", Namespace: "bee", Entries: hostEntries}); err != nil {
		return err
	}
	if err := resourcesModuleWrite(folder, filepath.Join("src", "probe", "_index.yaml"), resourcesModuleProbeIndex("bee.cred_probe", "cred-probe", "bee.test.cmod", []string{"funcs", "security", "json"})); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(folder, "src", "probe", "main.lua"), []byte(credentialsProbe), 0600); err != nil {
		return fmt.Errorf("write credentials probe: %w", err)
	}
	return nil
}

func resourcesModuleCloneEntry(entry map[string]interface{}) map[string]interface{} {
	clone := make(map[string]interface{}, len(entry))
	for key, value := range entry {
		clone[key] = value
	}
	return clone
}

func resourcesModuleDatabaseEnvironment(folder, placementRoot string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	environment := make([]string, 0, len(names)+1)
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(folder, name+".db"))
	}
	if placementRoot != "" {
		environment = append(environment, "BEE_PLACEMENT_ROOT="+placementRoot)
	}
	return environment
}

func resourcesModuleLoaded(folder, runtime string, environment []string) (map[string]struct{}, map[string]struct{}, error) {
	output, err := resourcesModuleRun(runtime, folder, environment, true, "registry", "list", "--json")
	if err != nil {
		return nil, nil, err
	}
	var entries []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(output), &entries); err != nil {
		return nil, nil, fmt.Errorf("decode registry list: %w\n%s", err, output)
	}
	namespaces := make(map[string]struct{})
	identities := make(map[string]struct{})
	for _, entry := range entries {
		identities[entry.ID] = struct{}{}
		if namespace, _, ok := strings.Cut(entry.ID, ":"); ok {
			namespaces[namespace] = struct{}{}
		}
	}
	return namespaces, identities, nil
}

func resourcesModuleCheckClosure(namespaces map[string]struct{}, identities map[string]struct{}) error {
	for namespace := range namespaces {
		for _, forbidden := range resourcesModuleForbidden {
			if namespace == forbidden || strings.HasPrefix(namespace, forbidden+".") {
				return fmt.Errorf("module pulled in forbidden namespace %s", namespace)
			}
		}
	}
	for identity := range identities {
		if strings.HasPrefix(identity, "bee.placement.native:runner") {
			return fmt.Errorf("module pulled in placement execution %s", identity)
		}
	}
	return nil
}

func resourcesModuleOneClosure(root, runtime string, credentials bool) error {
	prefix := "bee-res-mod-"
	if credentials {
		prefix = "bee-cred-mod-"
	}
	folder, err := os.MkdirTemp("", prefix)
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	defer os.RemoveAll(folder)
	if credentials {
		if err := resourcesModuleStageCredentials(root, folder, false); err != nil {
			return err
		}
	} else if err := resourcesModuleStageResources(root, folder, false); err != nil {
		return err
	}
	placementRoot := ""
	if !credentials {
		placementRoot = filepath.Join(folder, "resource-root")
		if err := os.Mkdir(placementRoot, 0700); err != nil {
			return fmt.Errorf("create resource root: %w", err)
		}
	}
	environment := resourcesModuleDatabaseEnvironment(folder, placementRoot)
	if _, err := resourcesModuleRun(runtime, folder, environment, true, "lint"); err != nil {
		return fmt.Errorf("%s closure lint failed: %w", map[bool]string{true: "credentials", false: "resources"}[credentials], err)
	}
	output, err := resourcesModuleRun(runtime, folder, environment, true, "run", map[bool]string{true: "cred-probe", false: "res-probe"}[credentials])
	if err != nil {
		return fmt.Errorf("%s closure probe failed: %w", map[bool]string{true: "credentials", false: "resources"}[credentials], err)
	}
	if !credentials {
		changedRoot := filepath.Join(folder, "resource-root-changed")
		if err := os.Mkdir(changedRoot, 0700); err != nil {
			return fmt.Errorf("create changed resource root: %w", err)
		}
		changedEnvironment := resourcesModuleDatabaseEnvironment(folder, changedRoot)
		if _, err := resourcesModuleRun(runtime, folder, changedEnvironment, true, "run", "res-probe", "changed"); err != nil {
			return fmt.Errorf("resources changed-root probe failed: %w", err)
		}
	}
	if credentials && strings.Contains(output, "module-secret-9c2e") {
		return fmt.Errorf("secret appeared in credentials probe output")
	}
	namespaces, identities, err := resourcesModuleLoaded(folder, runtime, environment)
	if err != nil {
		return err
	}
	return resourcesModuleCheckClosure(namespaces, identities)
}

func resourcesModuleMissingResources(root, runtime string) error {
	folder, err := os.MkdirTemp("", "bee-res-mod-bad-")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	defer os.RemoveAll(folder)
	if err := resourcesModuleStageResources(root, folder, true); err != nil {
		return err
	}
	environment := resourcesModuleDatabaseEnvironment(folder, filepath.Join(folder, "resource-root"))
	if _, err := resourcesModuleRun(runtime, folder, environment, true, "lint"); err != nil {
		return fmt.Errorf("resources missing-link lint failed: %w", err)
	}
	output, runErr := resourcesModuleRun(runtime, folder, environment, false, "run", "res-probe")
	if runErr != nil {
		return fmt.Errorf("resources missing-link probe: %w", runErr)
	}
	if !strings.Contains(strings.ToLower(output), "roots") {
		return fmt.Errorf("resources missing-link failure omitted roots reference\n%s", output)
	}
	return nil
}

func resourcesModuleMissingCredentials(root, runtime string) error {
	folder, err := os.MkdirTemp("", "bee-cred-mod-bad-")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	defer os.RemoveAll(folder)
	if err := resourcesModuleStageCredentials(root, folder, true); err != nil {
		return err
	}
	environment := resourcesModuleDatabaseEnvironment(folder, "")
	if _, err := resourcesModuleRun(runtime, folder, environment, true, "lint"); err != nil {
		return fmt.Errorf("credentials missing-link lint failed: %w", err)
	}
	output, runErr := resourcesModuleRun(runtime, folder, environment, false, "run", "cred-probe")
	if runErr != nil {
		return fmt.Errorf("credentials missing-link probe: %w", runErr)
	}
	if strings.Contains(output, "module-secret-9c2e") {
		return fmt.Errorf("secret appeared in credentials missing-link output")
	}
	return nil
}

func resourcesModuleRunAll(root, runtime string) error {
	if err := resourcesModuleOneClosure(root, runtime, false); err != nil {
		return err
	}
	if err := resourcesModuleMissingResources(root, runtime); err != nil {
		return err
	}
	if err := resourcesModuleOneClosure(root, runtime, true); err != nil {
		return err
	}
	if err := resourcesModuleMissingCredentials(root, runtime); err != nil {
		return err
	}
	return nil
}

func main() {
	rootFlag := flag.String("root", "..", "Bee repository root")
	runtimeFlag := flag.String("runtime", resourcesModuleRuntime, "Wippy runtime to verify")
	flag.Parse()
	root, err := filepath.Abs(*rootFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if info, err := os.Stat(runtime); err != nil || info.IsDir() {
		fmt.Fprintf(os.Stderr, "candidate runtime %q is unavailable\n", runtime)
		os.Exit(1)
	}
	if err := resourcesModuleRunAll(root, runtime); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
	fmt.Println("Resources and credentials load independently: public operations work, a missing binding fails clearly, an unauthorized actor is refused, no desktop/terminal/harness/placement/supervisor closure is pulled in, and no secret bytes escape")
}

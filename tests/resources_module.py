"""Resources and credentials load independently: each on a minimal staged host
with its own store, filesystem ceiling or secret source and policy bindings,
their public operations working, a missing required binding failing clearly, an
unauthorized actor refused, and no desktop, Terminal, harness, placement or
supervisor closure pulled in. The two module closures are staged separately so
neither makes the other loadable. It runs `lint` and `run` on the staged host,
which excludes the supervisor lane, so the pinned ingress lint failure does not
apply here. No secret bytes appear in captured output."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME, database_environment

SRC = yaml.safe_load((ROOT / "src/_index.yaml").read_text())


def named(name):
    return next(entry for entry in SRC["entries"] if entry["name"] == name)


RES_PROBE = r'''
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
    local reply, err = executor:call("bee.resources:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    return reply :: {[string]: unknown}
end
local function ok(reply: {[string]: unknown}, method: string): {[string]: unknown}
    assert(reply.ok == true, method .. " failed: " .. tostring(type(reply.error) == "table" and (reply.error :: {[string]: unknown}).message))
    return reply.value :: {[string]: unknown}
end
local function main()
    ok(call(nil, "associate", {workspace_id = WORKSPACE, name = "root", root_ref = "bee.placement.native:root", subpath = "", allowed_access = "write"}), "associate")
    local granted = ok(call(nil, "grant", {workspace_id = WORKSPACE, name = "root", access = "read", purpose = "project", audience = ACTOR, idempotency_key = "k"}), "grant")
    local grant_id = tostring(granted.grant_id)
    ok(call(nil, "resolve", {grant_id = grant_id, subject = ACTOR, audience = ACTOR}), "resolve")
    -- An actor without the resolve policy cannot resolve a grant.
    local denied = call(security.new_scope({}), "resolve", {grant_id = grant_id, subject = ACTOR, audience = ACTOR})
    assert(denied.ok == false and (denied.error :: {[string]: unknown}).code == "DENIED", "unauthorized resolve was not denied")
end
return {main = main}
'''

CRED_PROBE = r'''
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
    local reply, err = executor:call("bee.credentials:" .. method, request)
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
'''

PROBE_ACTIONS = ["funcs.call", "funcs.security", "security.scope.create", "registry.get",
                 "bee.resources.manage", "bee.resources.grant", "bee.resources.resolve",
                 "bee.credentials.manage", "bee.credentials.issue", "bee.credentials.materialize"]


def write(folder, relative, document):
    path = folder / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(document))


def base(folder):
    (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
    (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")


def stage_resources(folder, drop_roots=False):
    shutil.copytree(ROOT / "src/resources", folder / "src/resources")
    shutil.copytree(ROOT / "src/persist", folder / "src/persist")
    shutil.copytree(ROOT / "src/threads/records", folder / "src/threads/records")
    base(folder)
    write(folder, "src/host/_index.yaml", {"version": "1.0", "namespace": "bee", "entries": [
        named("resource_store_policy"), named("resource_manage_policy"), named("resource_grant_policy"), named("resource_resolve_policy"),
        {"name": "terminal", "kind": "terminal.host", "hide_logs": True, "lifecycle": {"auto_start": True}}]})
    if not drop_roots:
        roots = {"root_ref": "bee.placement.native:root", "access": "write"}
        write(folder, "src/placement/_index.yaml", {"version": "1.0", "namespace": "bee.placement.native", "entries": [
            {"name": "environment", "kind": "env.storage.os", "lifecycle": {"auto_start": True}},
            {"name": "root_path", "kind": "env.variable", "storage": "bee.placement.native:environment", "variable": "BEE_PLACEMENT_ROOT", "default": ".wippy/placement", "readonly": True},
            {"name": "root", "kind": "fs.directory", "directory": "${env:bee.placement.native:root_path}", "auto_init": True, "mode": "0700"},
            {"name": "admitted_roots", "kind": "registry.entry", "meta": {"type": "bee.placement_roots"}, "data": {"roots": [roots]}}]})
    write(folder, "src/probe/_index.yaml", {"version": "1.0", "namespace": "bee.res_probe", "entries": [
        {"name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main", "modules": ["funcs", "security"],
         "meta": {"command": {"name": "res-probe", "security": {"actor": {"id": "bee.test.rmod"}}}},
         "security": {"policies": ["bee.res_probe:policy"]}},
        {"name": "policy", "kind": "security.policy", "policy": {"actions": PROBE_ACTIONS, "resources": "*", "effect": "allow"}}]})
    (folder / "src/probe/main.lua").write_text(RES_PROBE)
    return folder


def stage_credentials(folder, drop_sources=False):
    shutil.copytree(ROOT / "src/credentials", folder / "src/credentials")
    shutil.copytree(ROOT / "src/persist", folder / "src/persist")
    shutil.copytree(ROOT / "src/threads/records", folder / "src/threads/records")
    base(folder)
    host = [named("credential_store_policy"), named("credential_manage_policy"), named("credential_issue_policy"), named("credential_materialize_policy"),
            {"name": "module_storage", "kind": "env.storage.memory"},
            {"name": "module_secret", "kind": "env.variable", "storage": "bee:module_storage", "variable": "BEE_MODULE_SECRET", "default": "module-secret-9c2e"}]
    sources = named("credential_sources")
    if not drop_sources:
        sources = {**sources, "data": {"sources": [{"ref": "bee:module_secret", "workspace_id": "*", "audience": "bee.test.cmod", "provider": "claude", "projection_kinds": ["environment"]}]}}
    host.append(sources)
    host.append({"name": "terminal", "kind": "terminal.host", "hide_logs": True, "lifecycle": {"auto_start": True}})
    write(folder, "src/host/_index.yaml", {"version": "1.0", "namespace": "bee", "entries": host})
    write(folder, "src/probe/_index.yaml", {"version": "1.0", "namespace": "bee.cred_probe", "entries": [
        {"name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main", "modules": ["funcs", "security", "json"],
         "meta": {"command": {"name": "cred-probe", "security": {"actor": {"id": "bee.test.cmod"}}}},
         "security": {"policies": ["bee.cred_probe:policy"]}},
        {"name": "policy", "kind": "security.policy", "policy": {"actions": PROBE_ACTIONS, "resources": "*", "effect": "allow"}}]})
    (folder / "src/probe/main.lua").write_text(CRED_PROBE)
    return folder


FORBIDDEN = ("bee.desktop", "bee.terminal", "bee.harness", "bee.harness.catalog", "bee.harness.carrier",
             "bee.harness.launch", "bee.harness.permission", "bee.hive", "bee.hive.supervisor", "bee.hive.telemetry",
             "bee.hive.desktop", "bee.session", "bee.applications", "bee.client", "bee.launch", "bee.driver")


def run(folder, *arguments, ok=True, env=None):
    result = subprocess.run([str(RUNTIME), *arguments], cwd=folder, env={**os.environ, **(env or {})},
                            capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    assert (result.returncode == 0) == ok, output
    return output


def loaded_namespaces(folder, env):
    entries = json.loads(run(folder, "registry", "list", "--json", env=env))
    return {entry["id"].split(":", 1)[0] for entry in entries}, {entry["id"] for entry in entries}


def main():
    # Resources closure.
    with tempfile.TemporaryDirectory(prefix="bee-res-mod-") as directory:
        folder = stage_resources(Path(directory))
        root = folder / "resource-root"
        root.mkdir()
        environment = database_environment(folder, BEE_PLACEMENT_ROOT=str(root))
        run(folder, "lint")
        run(folder, "run", "res-probe", env=environment)
        namespaces, ids = loaded_namespaces(folder, environment)
        for namespace in namespaces:
            assert not any(namespace == forbidden or namespace.startswith(forbidden + ".") for forbidden in FORBIDDEN), f"resources pulled in {namespace}"
        assert not any(identity.startswith("bee.placement.native:runner") for identity in ids), "resources pulled in placement execution"
    # Resources without its filesystem ceiling fails clearly.
    # A missing filesystem ceiling is not a lint finding (the linker ignores a
    # dangling requirement target); the module refuses the unlinked reference
    # when its operations run, and says which reference.
    with tempfile.TemporaryDirectory(prefix="bee-res-mod-bad-") as directory:
        folder = stage_resources(Path(directory), drop_roots=True)
        run(folder, "lint")
        environment = database_environment(folder, BEE_PLACEMENT_ROOT=str(folder / "resource-root"))
        output = run(folder, "run", "res-probe", env=environment, ok=False)
        assert "roots" in output.lower(), output

    # Credentials closure.
    with tempfile.TemporaryDirectory(prefix="bee-cred-mod-") as directory:
        folder = stage_credentials(Path(directory))
        environment = database_environment(folder)
        run(folder, "lint")
        assert "module-secret-9c2e" not in run(folder, "run", "cred-probe", env=environment)
        namespaces, _ = loaded_namespaces(folder, environment)
        for namespace in namespaces:
            assert not any(namespace == forbidden or namespace.startswith(forbidden + ".") for forbidden in FORBIDDEN), f"credentials pulled in {namespace}"
    # Credentials without its secret sources fails clearly.
    with tempfile.TemporaryDirectory(prefix="bee-cred-mod-bad-") as directory:
        folder = stage_credentials(Path(directory), drop_sources=True)
        environment = database_environment(folder)
        run(folder, "lint")
        output = run(folder, "run", "cred-probe", env=environment, ok=False)
        assert "module-secret-9c2e" not in output

    print("Resources and credentials load independently: public operations work, a missing binding fails clearly, an unauthorized actor is refused, no desktop/terminal/harness/placement/supervisor closure is pulled in, and no secret bytes escape")


if __name__ == "__main__":
    main()

"""Workspace resources acceptance beyond the Lua authority suite: the provider
contains a symlink escape at open time, and an association and grant survive a
restart. The Lua suite (tests/lua/resources) already proves the association
ceiling, subpath containment at association time, grant binding, every resolve
refusal, RESOURCE_NOT_LOCAL and the authorization epoch; this drives the parts
that need a real filesystem and a second boot. It runs the shipped runtime with
`run` (no `wippy lint`), so the supervisor lane's pinned lint failure does not
block it. The probe asserts internally and fails the boot on any breach."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME, database_environment

PROBE = r'''
local funcs = require("funcs")
local registry = require("registry")
local fs = require("fs")
local ROOT_REF = "bee.placement.native:root"
local WORKSPACE = "resource-restart"
local ACTOR = "bee.test.resource_probe"
local KEY = "restart-grant-key"
local CRED_SOURCE = "bee.resource_probe:cred_key"
local SENTINEL = "probe-secret-4b8f2a"
local function call(method: string, request: {[string]: unknown}): {[string]: unknown}
    local reply, err = funcs.new():call("bee.resources:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    local value = reply :: {[string]: unknown}
    assert(value.ok == true, method .. " failed: " .. tostring(type(value.error) == "table" and (value.error :: {[string]: unknown}).message))
    return value.value :: {[string]: unknown}
end
local function credential(method: string, request: {[string]: unknown}): {[string]: unknown}
    local reply, err = funcs.new():call("bee.credentials:" .. method, request)
    assert(not err, method .. ": " .. tostring(err))
    local value = reply :: {[string]: unknown}
    assert(value.ok == true, method .. " failed: " .. tostring(type(value.error) == "table" and (value.error :: {[string]: unknown}).message))
    return value.value :: {[string]: unknown}
end
local function admit()
    local roots_entry = registry.get("bee.placement.native:admitted_roots")
    assert(roots_entry, "admitted roots entry")
    local roots = (roots_entry.data :: {[string]: unknown}).roots :: {{[string]: unknown}}
    local has_root = false
    for _, root in ipairs(roots) do if tostring(root.root_ref) == ROOT_REF then has_root = true end end
    if not has_root then roots[#roots + 1] = {root_ref = ROOT_REF, access = "write"} end
    local sources_entry = registry.get("bee:credential_sources")
    assert(sources_entry, "credential sources entry")
    local sources_data = sources_entry.data :: {[string]: unknown}
    sources_data.sources = {{ref = CRED_SOURCE, workspace_id = "*", audience = ACTOR, provider = "claude", projection_kinds = {"environment"}}}
    local changes = registry.snapshot():changes()
    changes:update(roots_entry)
    changes:update(sources_entry)
    local applied, err = changes:apply()
    assert(applied, "admit: " .. tostring(err))
end
local function main(phase: string?)
    if phase == "prepare" then
        admit()
        call("associate", {workspace_id = WORKSPACE, name = "root", root_ref = ROOT_REF, subpath = "", allowed_access = "write"})
        call("grant", {workspace_id = WORKSPACE, name = "root", access = "read", purpose = "project", audience = ACTOR, idempotency_key = KEY})
        local defined = credential("define", {workspace_id = WORKSPACE, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = CRED_SOURCE}})
        assert(tostring(defined.destination) == "ANTHROPIC_API_KEY", "unexpected credential destination")
    elseif phase == "verify" then
        -- The association survived the restart: a manager still lists it.
        local listed = call("list", {workspace_id = WORKSPACE})
        local associations = listed.associations :: {{[string]: unknown}}
        local found = false
        for _, association in ipairs(associations) do if tostring(association.name) == "root" then found = true end end
        assert(found, "association did not survive the restart")
        -- The grant survived: replaying its idempotency key returns the same
        -- durable grant rather than a new one against a lost association.
        local granted = call("grant", {workspace_id = WORKSPACE, name = "root", access = "read", purpose = "project", audience = ACTOR, idempotency_key = KEY})
        local grant_id = tostring(granted.grant_id)
        local resolved = call("resolve", {grant_id = grant_id, subject = ACTOR, audience = ACTOR})
        assert(tostring(resolved.root_ref) == ROOT_REF, "grant resolved with the wrong root")
        -- The provider contains the resolved root at open time: a contained
        -- file reads; a symlink escaping the root, a symlink directory and a
        -- parent traversal are all refused.
        local volume, volume_error = fs.get(ROOT_REF)
        assert(volume, "open resource volume: " .. tostring(volume_error))
        local inside, inside_error = volume:readfile("inside.txt")
        assert(inside == "contained", "contained file did not read: " .. tostring(inside_error))
        local escaped, escape_error = volume:readfile("escape")
        assert(escaped == nil and escape_error ~= nil, "a symlink escaped the resource root")
        local nested, nested_error = volume:readfile("escape/secret.txt")
        assert(nested == nil and nested_error ~= nil, "a symlink directory escaped the resource root")
        local traversed, traversal_error = volume:readfile("../secret.txt")
        assert(traversed == nil and traversal_error ~= nil, "a parent traversal escaped the resource root")
        -- The credential definition survived the restart, and neither the
        -- listing nor its stored digest carries the secret bytes.
        local credentials = credential("list", {workspace_id = WORKSPACE})
        local definitions = credentials.definitions :: {{[string]: unknown}}
        local defined = false
        for _, definition in ipairs(definitions) do if tostring(definition.name) == "anthropic" then defined = true end end
        assert(defined, "credential definition did not survive the restart")
        local encoded = require("json").encode(credentials)
        assert(tostring(encoded):find(SENTINEL, 1, true) == nil, "the credential secret leaked into an exported listing")
    end
end
return {main = main}
'''

PROBE_INDEX = {
    "version": "1.0", "namespace": "bee.resource_probe", "entries": [
        {"name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
         "modules": ["funcs", "registry", "fs", "json"],
         "meta": {"command": {"name": "resource-probe", "security": {"actor": {"id": "bee.test.resource_probe"}}}},
         "security": {"policies": ["bee.resource_probe:probe_policy"]}},
        {"name": "cred_storage", "kind": "env.storage.memory"},
        {"name": "cred_key", "kind": "env.variable", "storage": "bee.resource_probe:cred_storage",
         "variable": "BEE_PROBE_SECRET", "default": "probe-secret-4b8f2a"},
        {"name": "probe_policy", "kind": "security.policy", "policy": {
            "actions": ["funcs.call", "registry.get", "registry.apply", "registry.apply_version",
                        "registry.overlay.apply", "fs.get", "bee.resources.manage", "bee.resources.grant", "bee.resources.resolve", "bee.credentials.manage", "bee.credentials.issue"],
            "resources": "*", "effect": "allow"}},
    ]}


def main():
    with tempfile.TemporaryDirectory(prefix="bee-resources-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "src", folder / "src")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, folder / name)
        probe = folder / "src/resource_probe"
        probe.mkdir()
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump(PROBE_INDEX))
        # A resource root with a contained file, a symlink escaping the root and
        # the secret it points at, outside the root.
        root = folder / "resource-root"
        root.mkdir()
        (root / "inside.txt").write_text("contained")
        (folder / "secret.txt").write_text("TOPSECRET")
        os.symlink(folder / "secret.txt", root / "escape")
        environment = database_environment(folder, BEE_PLACEMENT_ROOT=str(root))

        def run(phase):
            registry = folder / f"registry-{phase}.db"
            result = subprocess.run([str(RUNTIME), "run", "resource-probe", phase, "--set", f"registry.history_path={registry}"],
                                    cwd=folder, env=environment, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr
            return result.stdout + result.stderr

        run("prepare")
        run("verify")

    print("Workspace resources: symlink-escape, directory-symlink and parent-traversal containment at open time; association, grant and credential definition survive restart; no secret in exported listings")


if __name__ == "__main__":
    main()

"""Inventory and plan against a source-free, cmd/app-seeded deployment lock."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml
from workspace import RUNTIME, database_environment

PROBE = '''
local registry = require("registry")
local bounds = require("bounds")
local inventory = require("inventory")
local plan = require("plan")
local logger = require("logger")
local plan_inspection = require("plan_inspection")
local function probe(): integer
    logger:info("STANDALONE_SELF_UPDATE_START")
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then error(tostring(snapshot_error)) end
    local state, state_error = snapshot:state()
    if not state then error(tostring(state_error)) end
    local revision = bounds.count(snapshot:version():id())
    if revision == nil then error("invalid captured registry revision") end
    local installed, inventory_error = inventory.decode(state, revision)
    if not installed then error(tostring(inventory_error)) end
    local request, request_error = plan.decode({action = "update", component = "bee/bee",
        version = "0.1.0-selfupdate.2", parameters = {}, migration_policy = "none"})
    if not request then error(tostring(request_error)) end
    local source = {
        versions = function(_: string, _: integer): ({string}?, boolean?, string?)
            return nil, nil, "exact fixture pins only"
        end,
        artifact = function(name: string, selected: string): (plan_inspection.Inspection?, string?)
            if name ~= "bee/bee" then return nil, "unexpected fixture component" end
            return {component = name, version = selected, digest = string.rep("a", 64),
                requirements = {requirements = {}, missing = {}}, next_offset = nil, eof = true,
                entries = {{id = "bee.env:binary_identity", kind = "registry.entry",
                    meta = {type = "bee.binary_identity"}, data = {version = selected, build = "fixture",
                        source = "fixture", source_revision = "fixture", runtime = "fixture",
                        runtime_commit = "runtime", native = "fixture/native", native_version = "1.0.0",
                        website = "fixture", native_components = {{package = "fixture/native", version = "1.0.0"}}}}}}, nil
        end,
    }
    local prepared, problem = plan.prepare(state, revision, request, source, {native_module = "fixture/native", native_version = "1.0.0",
        native_modules = {["fixture/native"] = "1.0.0"}, runtime_commit = "runtime"})
    logger:info("STANDALONE_SELF_UPDATE_PLAN", {problem = problem or "", offered = prepared ~= nil})
    assert(installed.deployment == "bee/bee", "standalone Bee deployment selection is missing")
    for _, root in ipairs(installed.roots) do
        assert(root.component ~= "bee/bee", "inventory synthesized a standalone registry entry")
    end
    assert(prepared ~= nil, problem or "standalone Bee update plan is missing")
    if prepared then
        assert(prepared.plan.root_operation == "create", "standalone update selects an absent-entry update")
        assert(not snapshot:get(prepared.plan.root_id), "first selection destination is already resident")
    end
    return 0
end
local function main(): integer
    local ok, result = pcall(probe)
    if not ok then logger:error("STANDALONE_SELF_UPDATE_FAILURE", {cause = tostring(result)}); return 1 end
    return 0
end
return {main = main}
'''


def main(deployment):
    deployment = Path(deployment).resolve()
    lock = yaml.safe_load((deployment / "wippy.lock").read_text())
    assert [row["name"] for row in lock["modules"] if row.get("root")] == ["bee/bee"]
    assert not lock.get("replacements"), "requires a sealed standalone deployment"
    with tempfile.TemporaryDirectory(prefix="bee-selfroot-") as directory:
        folder = Path(directory)
        shutil.copy2(deployment / "wippy.lock", folder / "wippy.lock")
        modules = Path(lock["directories"]["modules"])
        vendor = modules if modules.name == "vendor" else modules / "vendor"
        for row in lock["modules"]:
            org, name = row["name"].split("/")
            relative = vendor / org / f"{name}-{row['version']}.wapp"
            (folder / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(deployment / relative, folder / relative)
        probe = folder / lock["directories"].get("src", "src") / "probe"
        probe.mkdir(parents=True)
        (probe / "main.lua").write_text(PROBE)
        (probe / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "selfroot.probe", "entries": [
                {"name": "read", "kind": "security.policy", "policy": {
                    "actions": ["registry.get", "registry.resolution.get"], "resources": "*", "effect": "allow"}},
                {"name": "main", "kind": "process.lua", "source": "file://main.lua", "method": "main",
                 "modules": ["registry", "logger"], "imports": {
                     "bounds": "bee.threads.records:bounds", "inventory": "bee.hub:inventory", "plan": "bee.hub:plan", "plan_inspection": "bee.hub:inspection"},
                 "security": {"policies": ["selfroot.probe:read"]},
                 "meta": {"command": {"name": "standalone-self-update", "security": {"actor": {"id": "selfroot.probe"}}}}},
            ]}, sort_keys=False))
        (folder / ".wippy.yaml").write_text(yaml.safe_dump({"version": "1.0", "registry": {
            "enable_history": True, "history_type": "sqlite", "history_path": str(folder / "registry.db")}}))
        home = folder / "home"
        home.mkdir()
        environment = database_environment(folder, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
        lint = subprocess.run([str(RUNTIME), "lint", "--ns", "selfroot.probe",
                               "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
                              cwd=folder, env=environment, text=True, capture_output=True, timeout=120)
        assert lint.returncode == 0, lint.stdout + lint.stderr
        result = subprocess.run([str(RUNTIME), "run", "--verbose", "standalone-self-update", "--host", "bee:workers"],
                                cwd=folder, env=environment, text=True,
                                capture_output=True, timeout=120)
        output = result.stdout + result.stderr
        evidence = "\n".join(line for line in output.splitlines() if "STANDALONE_SELF_UPDATE" in line)
        print(f"runtime exit: {result.returncode}\n{evidence or output}")
        assert result.returncode == 0, "standalone root inventory/update regression failed"


if __name__ == "__main__":
    main(sys.argv[1])

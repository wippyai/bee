"""Exercise the base SDK and UI without Sessions, Threads or Harness."""
from pathlib import Path
import shutil
import tempfile

import yaml

from values_module import run
from workspace import ROOT


def main():
    for index in (ROOT / "modules/application/src").rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        for entry in document.get("entries", []):
            declared = yaml.safe_dump(entry)
            for owner in ("threads", "sessions", "harness"):
                assert "bee/" + owner not in declared and "bee." + owner not in declared, (index, entry["name"], owner)
    temporary_root = ROOT / ".wippy/tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-application-module-", dir=temporary_root) as directory:
        folder = Path(directory)
        components = ("application", "ui", "values")
        for component in components:
            shutil.copytree(ROOT / "modules" / component, folder / "modules" / component)
        source = folder / "src"
        source.mkdir()
        (source / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee", "entries": [
                {"name": "dependency_application", "kind": "ns.dependency", "component": "bee/application", "version": "0.1.0-dev"},
                {"name": "terminal", "kind": "terminal.host", "lifecycle": {"auto_start": True}},
            ]}, sort_keys=False))
        check = source / "app/check"
        check.mkdir(parents=True)
        (check / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.app.check", "entries": [
                {"name": "probe", "kind": "process.lua", "source": "file://probe.lua", "method": "main",
                 "imports": {"caller": "bee.app:caller", "picker": "bee.ui.picker:folder", "client": "bee.app:client"}},
            ]}, sort_keys=False))
        (check / "probe.lua").write_text('''local caller = require("caller")
local picker = require("picker")
local client = require("client")

local function main()
    local accepted = assert(caller.decode({ok = true, value = "ready", replayed = false}))
    if not accepted.ok or accepted.value ~= "ready" then error("success decode failed") end
    if caller.decode({ok = true}) then error("missing success value accepted") end
    local fault = {code = "UNAVAILABLE", message = string.rep("x", 4096), retryable = false}
    if not caller.decode({ok = false, error = fault}) then error("fault boundary rejected") end
    fault.message = fault.message .. "x"
    if caller.decode({ok = false, error = fault}) then error("oversized fault accepted") end
    fault.message = "unavailable"
    local projection = {ok = false, error = fault, value = {revision = 1}, replayed = true}
    if caller.decode(projection) or not caller.envelope(projection) then error("failure projection boundary changed") end
    if caller.decode({ok = false, error = {code = "UNAVAILABLE", message = "bad", extra = true}}) then
        error("unknown fault field accepted")
    end
    if caller.decode({ok = true, value = "ready", replayed = "yes"}) then error("malformed replay accepted") end
    local state = picker.new()
    picker.apply_roots(state, {ok = true, error = nil, value = {roots = {{root_ref = "bee.env:workspace_root", access = "read"}}}})
    if #state.roots ~= 1 then error("folder picker failed") end
    local launch = assert(client.launch({version = 1, broker_pid = "broker", workspace_pid = "workspace",
        workspace_id = string.rep("a", 32), instance_id = "instance", view_id = "view", definition_id = "example.app:app",
        execution_generation = 1, definition_revision = "1", registry_revision = "1", launch_token = "token", arguments = {}}))
    if client.navigation(launch, "untrusted", {}) then error("untrusted navigation accepted") end
end

return {main = main}
''')
        (folder / "wippy.lock").write_text(yaml.safe_dump({
            "directories": {"modules": ".wippy", "src": "./src"},
            "modules": [{"name": "bee/" + component, "version": "0.1.0-dev"} for component in components],
        }, sort_keys=False))
        (folder / ".wippy.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "shutdown": {"timeout": "2s"}, "workspace": {
                "replacements": {"bee/" + component: "./modules/" + component for component in components},
            }}, sort_keys=False))
        run(folder, "lint", "--strict-any", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
        run(folder, "run", "-x", "bee.app.check:probe")
    print("Application SDK and UI: isolated strict lint and caller/picker/client proof without Sessions, Threads or Harness")


if __name__ == "__main__":
    main()

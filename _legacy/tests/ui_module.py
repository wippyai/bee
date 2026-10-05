"""Exercise the UI kits with only bee/ui and bee/values, from source and packs."""
from pathlib import Path
import hashlib
import shutil
import tempfile

import yaml

from values_module import run
from workspace import ROOT


def main():
    temporary_root = ROOT / ".wippy/tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-ui-module-", dir=temporary_root) as directory:
        folder = Path(directory)
        modules = ("ui", "values")
        for name in modules:
            shutil.copytree(ROOT / "modules" / name, folder / "modules" / name)
        source = folder / "src"
        source.mkdir()
        (source / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee", "entries": [
                {"name": "terminal", "kind": "terminal.host", "lifecycle": {"auto_start": True}},
                {"name": "dependency_ui", "kind": "ns.dependency", "component": "bee/ui", "version": "0.1.0-dev"},
            ],
        }, sort_keys=False))
        check = source / "ui/check"
        check.mkdir(parents=True)
        (check / "_index.yaml").write_text(yaml.safe_dump({
            "version": "1.0", "namespace": "bee.ui.check", "entries": [{
                "name": "probe", "kind": "process.lua", "source": "file://probe.lua", "method": "main",
                "modules": ["tty"],
                "imports": {"frame": "bee.ui:frame", "appearance": "bee.ui:appearance",
                            "text": "bee.ui:text",
                            "forms": "bee.ui.forms:forms", "viz": "bee.ui.viz:viz",
                            "diagram": "bee.ui.diagram:diagram", "picker": "bee.ui.picker:folder"},
            }],
        }, sort_keys=False))
        (check / "probe.lua").write_text("""local frame = require("frame")
local appearance = require("appearance")
local forms = require("forms")
local viz = require("viz")
local diagram = require("diagram")
local picker = require("picker")
local text = require("text")
local tty = require("tty")

local function main()
    local preferences = appearance.defaults()
    assert(appearance.decode(preferences), "invalid default preferences")
    assert(text.bound("A\\nB", 8) == "A B", "text retained a control")
    assert(text.bound("aéz", 2) == "a…", "text split a UTF-8 character")
    for _, size in ipairs({{120, 36}, {80, 24}}) do
        local painter = frame.new(size[1], size[2], preferences)
        frame.header(painter, "ISOLATED UI", "ready")
        frame.footer(painter, "ready", "Esc close")
        local rows = frame.rows(painter)
        assert(#rows == size[2], "incorrect row count")
        for _, row in ipairs(rows) do
            assert(tty.text.width(row) == size[1], "incorrect row width")
        end
        assert(rows[1]:find("ISOLATED UI", 1, true), "missing header")
    end
    local painter = frame.new(40, 12, appearance.defaults())
    local form = forms.form_new({forms.field_text("name", "Name", "Bee", {required = true})})
    if not forms.validate(form) then error("isolated form failed") end
    forms.draw(painter, {x = 1, y = 1, width = 40, height = 3}, form, 1)
    viz.sparkline(painter, 1, 4, 40, {1, 2, 3})
    if diagram.flame(painter, {x = 1, y = 5, width = 40, height = 3}, {label = "UI", value = 1}) ~= 1 then
        error("isolated diagram failed")
    end
    local state = picker.new()
    picker.apply_roots(state, {ok = true, value = {roots = {{root_ref = "fixture:root", access = "read"}}}})
    if #state.roots ~= 1 or not picker.open(state) then error("isolated picker failed") end
    local intent = picker.folders_intent(state)
    if not intent or intent.target ~= "bee.workspace.binding:folders" then error("picker intent changed") end
    if #frame.rows(painter) ~= 12 then error("isolated painter failed") end
end

return {main = main}
""")
        lock = {"directories": {"modules": ".wippy", "src": "./src"},
                "modules": [{"name": f"bee/{name}", "version": "0.1.0-dev"} for name in modules]}
        (folder / "wippy.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
        configuration = {"version": "1.0", "shutdown": {"timeout": "2s"}, "workspace": {
            "replacements": {f"bee/{name}": f"./modules/{name}" for name in modules}}}
        (folder / ".wippy.yaml").write_text(yaml.safe_dump(configuration, sort_keys=False))
        run(folder, "lint", "--strict-any", "--set", "lua.type_system.enabled=true",
            "--set", "lua.type_system.strict=true", "--set", "lua.type_system.strict_any=true")
        run(folder, "run", "-x", "bee.ui.check:probe")
        vendor = folder / ".wippy/vendor/bee"
        vendor.mkdir(parents=True)
        for name in modules:
            pack = vendor / f"{name}-0.1.0-dev.wapp"
            run(folder, "pack", "--module", f"bee/{name}", str(pack))
            assert pack.is_file() and pack.stat().st_size > 0, f"{name} pack was not created"
            module = next(item for item in lock["modules"] if item["name"] == f"bee/{name}")
            module["hash"] = "sha256:" + hashlib.sha256(pack.read_bytes()).hexdigest()
        (folder / "wippy.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
        shutil.rmtree(folder / "modules")
        del configuration["workspace"]
        (folder / ".wippy.yaml").write_text(yaml.safe_dump(configuration, sort_keys=False))
        run(folder, "run", "-x", "bee.ui.check:probe")
    print("UI module: isolated strict lint and source/packed kits without application, Harness or Threads")


if __name__ == "__main__":
    main()

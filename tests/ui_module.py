"""Exercise the UI package without the application SDK or owner services."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from workspace import ROOT, RUNTIME


def main():
    temporary_root = ROOT / ".wippy/tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-ui-module-", dir=temporary_root) as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "modules/ui", folder / "modules/ui")
        source = folder / "src"
        source.mkdir()
        (source / "_index.yaml").write_text("""version: '1.0'
namespace: bee
entries:
- name: ui
  kind: ns.dependency
  component: bee/ui
  version: 0.1.0-dev
- name: terminal
  kind: terminal.host
  lifecycle: {auto_start: true}
""")
        check = source / "ui/check"
        check.mkdir(parents=True)
        (check / "_index.yaml").write_text("""version: '1.0'
namespace: bee.ui.check
entries:
- name: probe
  kind: process.lua
  source: file://probe.lua
  method: main
  modules: [tty]
  imports:
    appearance: bee.ui:appearance
    frame: bee.ui:frame
    text: bee.ui:text
""")
        (check / "probe.lua").write_text("""local appearance = require("appearance")
local frame = require("frame")
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
end

return {main = main}
""")
        (folder / "wippy.lock").write_text("""directories:
  modules: .wippy
  src: ./src
modules:
- name: bee/ui
  version: 0.1.0-dev
""")
        (folder / ".wippy.yaml").write_text("""version: '1.0'
shutdown: {timeout: 2s}
workspace:
  replacements:
    bee/ui: ./modules/ui
""")
        commands = [
            ["lint", "--strict-any", "--set", "lua.type_system.enabled=true",
             "--set", "lua.type_system.strict=true"],
            ["pack", "--module", "bee/ui", str(folder / "ui.wapp")],
            ["run", "-x", "bee.ui.check:probe"],
        ]
        for arguments in commands:
            subprocess.run([str(RUNTIME), *arguments], cwd=folder, check=True,
                           env={**os.environ, "TMPDIR": str(temporary_root)}, timeout=90)
        assert (folder / "ui.wapp").stat().st_size > 0, "UI pack is empty"
    print("UI module: isolated strict lint, module-only pack, frame/appearance/text probe")


if __name__ == "__main__":
    main()

"""Source/pack Modules input acceptance with deterministic fixture Hub replies.

The real facade and publication boundary are covered by hub-manage-check.
This fixture exercises the actual broker, app process, presenter and keyboard.
"""
import tempfile
from pathlib import Path

from tui_smoke import Desktop
from workspace import fixture_workspace, pack_fixture


FACADE = '''
local function handle(raw: unknown): {[string]: unknown}
    if type(raw) ~= "table" then return {ok = false, replayed = false} end
    if raw.operation == "catalog" then
        return {ok = true, replayed = false, value = {total = 1, items = {{
            component = "bee/example", title = "Preview fixture", description = "Packaged module",
            latest_version = "1.0.0"}}}}
    elseif raw.operation == "details" then
        return {ok = true, replayed = false, value = {component = "bee/example", title = "Preview fixture",
            description = "Packaged module", readme = "Fixture", page = 1, total_versions = 2,
            versions = {{version = "1.0.0", yanked = false}, {version = "0.9.0", yanked = false}}}}
    elseif raw.operation == "inspect" then
        return {ok = true, replayed = false, value = {requirements = {missing = {}, bindings = {}}}}
    end
    return {ok = false, replayed = false, code = "FIXTURE", message = "No fixture mutation"}
end
return {handle = handle}
'''


def exercise(project, packed, pack):
    with tempfile.TemporaryDirectory(prefix="bee-modules-ui-") as directory:
        (Path(directory) / ".wippy").mkdir()
        ui = Desktop(directory, packed=packed, project=project, pack_file=pack, apps=("bee.modules:app",))
        try:
            ui.wait("MODULES", timeout=20)
            ui.wait("Preview fixture", timeout=10)
            ui.wait("Keyword: bee")
            ui.key(b"K")
            ui.wait("Keyword (empty is all): bee")
            ui.key(b"\x7f\x7f\x7f\r")
            ui.wait("Keyword: all")
            ui.key(b"/")
            ui.key(b"terminal\r")
            ui.wait("Search: terminal")
            ui.key(b"\x1b[B")
            ui.key(b"\r")
            ui.wait("Packaged module")
            ui.wait("1.0.0")
            # Regression: j navigation previously swallowed this JSON shortcut.
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"example:settings\r")
            ui.wait("Parameter JSON value")
            ui.key(b'{"enabled":true}\r')
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"\x1b")
            ui.key(b"\x1b[24~")
            ui.wait("MODULES", timeout=8)
            ui.resize(60, 20)
            ui.wait("MODULES")
            ui.quit()
        finally:
            ui.close()


def main():
    with fixture_workspace(unit_tests=False) as project:
        (project / "src/hub/facade.lua").write_text(FACADE)
        pack = project / "modules-test.wapp"
        pack_fixture(project, pack)
        exercise(project, False, pack)
        exercise(project, True, pack)
    print("Modules source/pack: keyword/search, details, JSON shortcut, F12, resize and shutdown pass")


if __name__ == "__main__":
    main()

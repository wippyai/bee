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
            description = "Packaged module", readme = "# Fixture guide\\nRead this before installing.\\nPackage usage and configuration.", page = 1, total_versions = 2,
            versions = {{version = "1.0.0", yanked = false}, {version = "0.9.0", yanked = false}}}}
    elseif raw.operation == "inspect" then
        return {ok = true, replayed = false, value = {requirements = {missing = {}, bindings = {}}}}
    elseif raw.operation == "plan" then
        return {ok = true, replayed = false, value = {request = raw.request,
            digest = string.rep("a", 64), ready = true, base_revision = 1,
            modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {
                "fixture:01", "fixture:02", "fixture:03", "fixture:04", "fixture:05", "fixture:06",
                "fixture:07", "fixture:08", "fixture:09", "fixture:10", "fixture:11", "fixture:12",
                "fixture:last"}}}
    elseif raw.operation == "apply" then
        assert(raw.expected_digest == string.rep("a", 64), "confirmation lost the displayed digest")
        return {ok = true, replayed = false, value = {state = "complete", message = "Fixture confirmation received"}}
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
            ui.key("terminal café".encode())
            ui.key(b"\x7f\r")
            ui.wait("Search: terminal caf")
            ui.key(b"\x1b[B")
            ui.key(b"\r")
            ui.wait("Packaged module")
            ui.wait("1.0.0")
            ui.key(b"h")
            ui.wait("Fixture guide")
            ui.wait("Read this before installing.")
            ui.key(b"v")
            ui.wait("1.0.0")
            # Regression: j navigation previously swallowed this JSON shortcut.
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"example:settings\r")
            ui.wait("Parameter JSON value")
            ui.key(b'{"enabled": true, "title": "two words"}\r')
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"\x1b")
            ui.key(b"p")
            ui.wait("Ready for confirmation")
            assert "Fixture confirmation received" not in ui.text(), "planning applied the operation"
            ui.key(b"\x1b[B" * 20)
            ui.wait("fixture:last")
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\x1b")
            ui.wait("MODULES  PLAN")
            assert "Fixture confirmation received" not in ui.text(), "cancelling confirmation applied the operation"
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\r")
            ui.wait("Fixture confirmation received")
            ui.wait("Receipt state: complete")
            assert "Applying measured plan" not in ui.text(), "completed operation retained pending status"
            ui.key(b"\x1b[24~")
            ui.wait("MODULES", timeout=8)
            ui.resize(60, 20)
            ui.wait("MODULES")
            ui.quit()
        except Exception:
            Path("/tmp/bee-modules-ui-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


def main():
    with fixture_workspace(unit_tests=False) as project:
        (project / "src/hub/facade.lua").write_text(FACADE)
        pack = project / "modules-test.wapp"
        pack_fixture(project, pack)
        exercise(project, False, pack)
        exercise(project, True, pack)
    print("Modules source/pack: filters, README, JSON input, plan/review/cancel/confirm, completed receipt, F12, resize and shutdown pass")


if __name__ == "__main__":
    main()

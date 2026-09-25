"""Exercise uninstalled entry/files browsing through the Modules window."""
import tempfile
from pathlib import Path
from modules_app import FACADE
from tui_smoke import Desktop
from workspace import fixture_workspace, pack_fixture

READS = '''
    elseif raw.operation == "state" then
        return {ok = true, replayed = false, value = {component = "bee/example", version = "1.0.0", digest = string.rep("c", 64),
            entries = {{id = "example:main", kind = "function.lua", data = {source = "PREVIEW_ENTRY_BODY"}}},
            resources = {{id = "example:assets", type = "fs"}}}}
    elseif raw.operation == "files" then
        assert(raw.request.expected_digest == string.rep("c", 64), "filesystem read lost artifact fence")
        assert(raw.request.resource == "example:assets", "filesystem read lost resource")
        return {ok = true, replayed = false, value = {component = "bee/example", version = "1.0.0", digest = string.rep("c", 64),
            files = {{name = "guide.txt", type = "file"}}}}
    elseif raw.operation == "read_file" then
        assert(raw.request.path == "guide.txt" and raw.request.expected_digest == string.rep("c", 64), "file read lost selection")
        return {ok = true, replayed = false, value = {component = "bee/example", version = "1.0.0", digest = string.rep("c", 64), offset = 0,
            content_base64 = "UEFDS0FHRV9GSUxFX1BSRVZJRVc=", eof = true, size = 20}}
'''

def run():
    with fixture_workspace(unit_tests=False) as project:
        (project / "modules/hub/src/binding/facade.lua").write_text(FACADE.replace('    elseif raw.operation == "details" then', READS + '    elseif raw.operation == "details" then'))
        pack = project / "contents-deployment"
        pack_fixture(project, pack)
        for packed in (False, True):
            with tempfile.TemporaryDirectory(prefix="bee-contents-ui-") as directory:
                (Path(directory) / ".wippy").mkdir()
                ui = Desktop(directory, packed=packed, project=project, deployment=pack, apps=("bee.hub.modules:app",))
                try:
                    ui.wait("Preview fixture", timeout=20)
                    ui.key(b"\x1b[B\r")
                    ui.wait("Fixture guide")
                    ui.key(b"c")
                    ui.wait("example:assets")
                    ui.key(b"\r")
                    ui.wait("guide.txt")
                    ui.key(b"\r")
                    ui.wait("PACKAGE_FILE_PREVIEW")
                    ui.key(b"\x1b[24~")
                    ui.wait("PACKAGE_FILE_PREVIEW")
                    ui.resize(48, 18)
                    ui.wait("PACKAGE_FILE_PREVIEW")
                    ui.key(b"\x7f\x7f")
                    ui.wait("example:main")
                    ui.key(b"\x1b[B\r")
                    ui.wait("PREVIEW_ENTRY_BODY")
                    ui.key(b"h")
                    ui.wait("Fixture guide")
                    ui.quit()
                except Exception:
                    print(ui.text())
                    raise
                finally:
                    ui.close()
    print("Modules contents source/pack: exact artifact entry and file reads, navigation, F12, compact view, README return pass")

if __name__ == "__main__":
    run()

"""The Hive Manager boots under the application broker in the local profile:
the frame appears, the unavailable supervisor state is shown as such with this node
listed and nothing invented, opening the node reports the desktop catalog as
unavailable with its reason, a control request is refused before any owner is
asked, refresh works, and the app closes without enabling anything."""
import sys
import tempfile
import time
import yaml
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import fixture_workspace, pack_fixture



def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-hive-manager-") as directory:
        ui = Desktop(directory, apps=("bee.hive_manager:app",))
        try:
            ui.wait("HIVE MANAGER", timeout=20)
            ui.wait("Hive supervisor unavailable", timeout=10)
            text = ui.text()
            assert "FIXTURE DATA" not in text, text
            assert "this present" in text, text
            assert "unavailable" in text, text
            ui.key(b"\r")
            ui.wait("Desktops unavailable", timeout=5)
            ui.key(b"c")
            ui.pump(.4)
            assert "Select a desktop first" in ui.text(), ui.text()
            ui.key(b"r")
            ui.wait("HIVE MANAGER", timeout=5)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
    print("Hive Manager app: boots under the broker, shows the unavailable supervisor honestly, reports the desktop catalog reason, refuses control without a desktop, closes cleanly")


def slow_query(packed=False):
    # Delay the directory boundary in the disposable app, not the runtime.
    # Before the fix this prevents ready and every subsequent input event.
    with fixture_workspace(unit_tests=False) as project, tempfile.TemporaryDirectory(prefix="bee-hive-slow-") as directory:
        manifest = project / "src/apps/hive/_index.yaml"
        data = yaml.safe_load(manifest.read_text())
        for entry in data["entries"]:
            if entry["name"] == "directory":
                entry["modules"] = ["time"]
            elif entry["name"] == "source":
                entry["data"]["kind"] = "fixture"
        manifest.write_text(yaml.safe_dump(data, sort_keys=False))
        source = project / "src/apps/hive/directory.lua"
        code = source.read_text().replace('local types = require("types")', 'local types = require("types")\nlocal time = require("time")')
        code = code.replace('        local node = find(node_id)', '        time.sleep("8s")\n        local node = find(node_id)')
        source.write_text(code)
        pack = Path(directory) / "bee.wapp"
        if packed:
            pack_fixture(project, pack)
        ui = Desktop(directory, project=project, packed=packed, pack_file=pack, apps=("bee.hive_manager:app",))
        try:
            ui.wait("HIVE MANAGER", timeout=5)
            ui.wait("FIXTURE DATA", timeout=1)
            ui.key(b"t")
            ui.wait("Less", timeout=1)
            ui.key(b"r")
            ui.wait("Query in progress", timeout=1)
            start = time.monotonic()
            ui.key(b"\x1b")
            while "HIVE MANAGER" in ui.text() and time.monotonic() - start < 1:
                ui.pump(.05)
            assert "HIVE MANAGER" not in ui.text(), ui.text()
            ui.quit()
        finally:
            ui.close()
    print("Hive Manager slow query: first frame, keyboard and close stay responsive", "pack" if packed else "source")


def stale_confirmation(packed=False):
    # A reply already in flight may change the catalog/selection while the
    # shell displays its question. Reproduce that ordering at the app boundary.
    with fixture_workspace(unit_tests=False) as project, tempfile.TemporaryDirectory(prefix="bee-hive-confirm-") as directory:
        manifest = project / "src/apps/hive/_index.yaml"
        data = yaml.safe_load(manifest.read_text())
        for entry in data["entries"]:
            if entry["name"] == "source":
                entry["data"]["kind"] = "fixture"
            elif entry["name"] == "fixture":
                desktops = entry["data"]["catalogs"]["forge"]["desktops"]
                desktops.append({"workspace_id": desktops[0]["workspace_id"], "desktop_id": "a" * 32, "label": "replacement"})
        manifest.write_text(yaml.safe_dump(data, sort_keys=False))
        source = project / "src/apps/hive/app.lua"
        code = source.read_text()
        marker = "                local asked = dialog\n                dialog = nil"
        assert code.count(marker) == 1
        code = code.replace(marker, marker + "\n                model.move(state, 1)")
        source.write_text(code)
        pack = Path(directory) / "bee.wapp"
        if packed:
            pack_fixture(project, pack)
        ui = Desktop(directory, project=project, packed=packed, pack_file=pack, apps=("bee.hive_manager:app",))
        try:
            ui.wait("HIVE MANAGER", timeout=10)
            ui.wait("ready", timeout=5)
            ui.pump(.3)
            ui.key(b"\r")
            ui.wait("main", timeout=5)
            ui.key(b"c")
            ui.wait("Take control of this desktop?", timeout=3)
            ui.key(b"\t\r")
            ui.wait("Desktop selection changed", timeout=3)
            assert "Attached control" not in ui.text(), ui.text()
            ui.key(b"\x1b")
            ui.pump(.3)
            ui.quit()
        finally:
            ui.close()
    print("Hive Manager confirmation refuses changed target without dispatch", "pack" if packed else "source")


if __name__ == "__main__":
    exercise()
    slow_query()
    slow_query(packed=True)
    stale_confirmation()
    stale_confirmation(packed=True)

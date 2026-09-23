"""User-owned window labels and accents, independent from application input."""
import tempfile
import shutil
import subprocess
from pathlib import Path
from workspace import ROOT, RUNTIME
from tui_smoke import Desktop
from recovery import client_stored


def menu(ui, title, action):
    y, line = next((y, line) for y, line in enumerate(ui.screen.display, 1) if title in line and "×" in line)
    ui.mouse(2, line.index(title) + 1, y)
    ui.mouse(2, line.index(title) + 1, y, True)
    ui.choose(action)


def rename(ui, title, value):
    menu(ui, title, "Rename…")
    ui.wait("Rename application")
    ui.key(value.encode() + b"\t ")
    ui.wait(value)
    ui.pump(.2)
    assert "Rename application" not in ui.text(), ui.text()


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-personalize-") as directory:
        ui = Desktop(directory, packed, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS")
            rename(ui, "Settings", "Workspace Colors")
            assert "Workspace Colors" in ui.screen.display[0], ui.text()
            menu(ui, "Workspace Colors", "Accent")
            ui.choose("Rose")
            ui.pump(.2)
            tab_color = ui.screen.buffer[0][ui.screen.display[0].index("Workspace Colors")].bg
            assert tab_color == "ffa5c5", (tab_color, ui.text())
            ui.key(b"\x1b[24~")
            ui.wait("Workspace Colors")
            ui.window_control("−")
            ui.pump(.2)
            x = ui.screen.display[0].index("Workspace Colors") + 1
            ui.mouse(0, x, 1)
            ui.mouse(0, x, 1, True)
            ui.wait("BEE SETTINGS")
            ui.quit()
            ui.close()
            ui = Desktop(directory, packed)
            ui.wait("Workspace Colors")
            ui.wait("BEE SETTINGS")
            assert ui.screen.buffer[0][ui.screen.display[0].index("Workspace Colors")].bg == tab_color
            menu(ui, "Workspace Colors", "Rename…")
            ui.key(b"Discarded\x1b[Z\r")
            ui.wait("Workspace Colors")
            assert "Discarded" not in ui.text(), ui.text()
            menu(ui, "Workspace Colors", "Rename…")
            ui.key(b"\x7f\r")
            ui.pump(.2)
            assert "Settings" in ui.screen.display[0] and "Workspace Colors" not in ui.screen.display[0], ui.text()
            ui.quit()
        finally:
            ui.close()
    print(f'Personalization {"pack" if packed else "source"}: rename, accent, cancel/clear, minimized restore, F12 and cold recovery')


def unauthorized_application():
    with tempfile.TemporaryDirectory(prefix="bee-title-denial-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        source = project / "src/apps/settings/app.lua"
        code = source.read_text()
        anchor = "            local data = event.value"
        assert anchor in code
        code = code.replace(anchor, anchor + """
            assert(process.send(launch.workspace_pid, "bee.desktop.command", {version = 1,
                op = "personalize", id = launch.view_id, user_title = "Bypassed", accent = "rose"}))
            status = "Attempt sent"
""")
        source.write_text(code)
        ui = Desktop(directory, project=project, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS")
            ui.key(b"\t")
            ui.wait("Attempt sent")
            ui.pump(.3)
            assert "Settings" in ui.screen.display[0] and "Bypassed" not in ui.text(), ui.text()
            ui.quit()
        finally:
            ui.close()
    print("Application cannot bypass presenter ownership to personalize a window")


def terminals(packed):
    with tempfile.TemporaryDirectory(prefix="bee-terminal-labels-") as directory:
        ui = Desktop(directory, packed, apps=("bee.console:app",))
        try:
            ui.wait("Terminal")
            rename(ui, "Terminal", "Build")
            ui.key(b"printf 'FIRST_%s\\n' CLEAN\r")
            ui.wait("FIRST_CLEAN")
            ui.open_start()
            ui.choose("Terminal")
            ui.wait("Terminal")
            rename(ui, "Terminal", "Review")
            ui.key(b"printf 'SECOND_%s\\n' CLEAN\r")
            ui.wait("SECOND_CLEAN")
            assert "Build" in ui.screen.display[0] and "Review" in ui.screen.display[0], ui.text()
            assert "command not found" not in ui.text(), ui.text()
            ui.quit(confirm=True)
        finally:
            ui.close()
    print(f'Terminal labels {"pack" if packed else "source"}: independent names and modal input isolation')


def acknowledged_layout():
    """A successful acknowledgement commits even without its scene notification."""
    with tempfile.TemporaryDirectory(prefix="bee-layout-ack-") as directory:
        root = Path(directory)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        session = project / "src/core/session/main.lua"
        code = session.read_text()
        anchor = 'if desktop ~= before or command.op == "snapshot" or command.op == "place" then send_scene() end'
        assert code.count(anchor) == 1
        session.write_text(code.replace(anchor,
            'if command.op ~= "personalize" and (desktop ~= before or command.op == "snapshot" or command.op == "place") then send_scene() end'))
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, check=True)
        pack = root / "ack.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("pack" if packed else "source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack, apps=("bee.settings:app",))
            try:
                ui.wait("BEE SETTINGS")
                rename(ui, "Settings", "Committed label")
                saved = client_stored(folder)
                assert saved["scene"]["windows"][0]["user_title"] == "Committed label", "Acknowledged label was not committed"
                # No graceful quit/save handshake may rescue an uncommitted update.
                ui.process.kill()
                ui.process.wait(timeout=3)
            finally:
                ui.close()
            ui = Desktop(folder, packed, project=project, pack_file=pack)
            try:
                ui.wait("Committed label")
                ui.quit()
            finally:
                ui.close()
    print("Layout acknowledgement source/pack: scene notification withheld, label committed before success, abrupt-exit recovery")


if __name__ == "__main__":
    acknowledged_layout()
    unauthorized_application()
    for packed in (False, True):
        exercise(packed)
        terminals(packed)

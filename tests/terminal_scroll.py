"""Nested Terminal history through physical SGR wheel events, source and pack."""
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

from tui_smoke import Desktop, ROOT, RUNTIME


def scroll_terminal(ui):
    ui.key(b"for n in {1..80}; do printf 'SCROLL_ROW_%03d\\n' $n; done\r")
    ui.wait("SCROLL_ROW_080")
    # Target actual Terminal content even when another application is behind it.
    y, line = next((y, line) for y, line in enumerate(ui.screen.display, 1)
                   if "SCROLL_ROW_080" in line)
    x = line.index("SCROLL_ROW_080") + 1
    live = ui.text()
    # One discrete wheel notch must change the nested viewport.
    ui.mouse(64, x, y)
    assert ui.text() != live, "Wheel did not move nested Terminal history"
    # Trackpads arrive as a burst of the same terminal wheel protocol.
    # Send the burst in one write; no artificial inter-event delays.
    ui.key((f"\x1b[<64;{x};{y}M" * 12).encode())
    ui.wait("SCROLL_ROW_040")
    ui.key((f"\x1b[<65;{x};{y}M" * 40).encode())
    ui.wait("SCROLL_ROW_080")
    # Keyboard input leaves history and still reaches the same shell.
    ui.mouse(64, x, y)
    ui.key(b"printf 'SCROLL_%s\\n' KEYBOARD_OK\r")
    ui.wait("SCROLL_KEYBOARD_OK")


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-terminal-scroll-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in ("wippy.lock", ".wippy.yaml", "wippy.yaml"):
        shutil.copytree(ROOT / "modules", project / "modules")
            shutil.copy2(ROOT / name, project / name)
        index = project / "src/apps/console/_index.yaml"
        document = yaml.safe_load(index.read_text())
        executor = next(entry for entry in document["entries"] if entry["name"] == "executor")
        executor["default_env"].update({"HOME": str(folder), "HISTFILE": "/dev/null", "PS1": "$ "})
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        pack = folder / "scroll.wapp"
        if packed:
            subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        ui = Desktop(folder, packed, project=project, pack_file=pack, apps=("bee.console:app",))
        try:
            ui.wait("Terminal")
            scroll_terminal(ui)
            ui.quit(confirm=True)
            print(f"Terminal scroll {'pack' if packed else 'source'}: notch, burst, down, keyboard")
        finally:
            ui.close()


if __name__ == "__main__":
    exercise(False)
    exercise(True)

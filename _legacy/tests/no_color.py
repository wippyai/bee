"""NO_COLOR reaches the real presenter and admitted application processes."""
import os
from pathlib import Path
import re
import tempfile
from unittest.mock import patch

from tui_smoke import Desktop


def exercise():
    with patch.dict(os.environ, {"NO_COLOR": "1"}), tempfile.TemporaryDirectory(prefix="bee-no-color-") as directory:
        ui = Desktop(Path(directory))
        try:
            ui.wait("SESSIONS")
            for width, height in ((120, 36), (80, 24)):
                ui.resize(width, height)
                ui.pump(.5)
                for line in ui.screen.buffer.values():
                    for char in line.values():
                        for color in (char.fg, char.bg):
                            assert not re.fullmatch(r"[0-9a-fA-F]{6}", str(color)), (width, color, ui.text())
                assert "New session" in ui.text(), ui.text()
                ui.key(b"?")
                ui.wait("HELP")
                ui.key(b"\x1b")
            ui.quit()
        finally:
            ui.close()
    print("NO_COLOR: real Sessions, presenter and keyboard help at 120x36 and 80x24")


if __name__ == "__main__":
    exercise()

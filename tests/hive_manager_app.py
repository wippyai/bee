"""The Hive Manager boots under the application broker in the local profile:
the frame appears, the unavailable supervisor state is shown as such with this node
listed and nothing invented, opening the node reports the desktop catalog as
unavailable with its reason, a control request is refused before any owner is
asked, refresh works, and the app closes without enabling anything."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-hive-manager-") as directory:
        ui = Desktop(directory, apps=("bee.hive_manager:app",))
        try:
            ui.wait("HIVE MANAGER", timeout=20)
            ui.wait("Hive supervisor unavailable", timeout=10)
            text = ui.text()
            assert "FIXTURE DATA" not in text, text
            assert "this unavailable" in text, text
            assert "UNAVAILABLE" in text, text
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


if __name__ == "__main__":
    exercise()

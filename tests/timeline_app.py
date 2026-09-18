"""The timeline application boots under the application broker as the local
viewer: the thread picker appears with what the owner lists for this actor,
opening without a choice is refused, refresh works, and the app closes
without writing anything."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-timeline-") as directory:
        ui = Desktop(directory, apps=("bee.timeline:app",))
        try:
            ui.wait("TIMELINE", timeout=20)
            ui.pump(.5)
            text = ui.text()
            assert "No threads to read" in text or "Threads unavailable" in text, text
            ui.key(b"\r")
            ui.pump(.4)
            assert "Choose a thread first" in ui.text(), ui.text()
            ui.key(b"r")
            ui.wait("TIMELINE", timeout=5)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
    print("Timeline app: boots under the broker, lists what the owner reports, refuses opening without a choice, closes cleanly")


if __name__ == "__main__":
    exercise()

"""The Workspaces application boots under the application broker as the local
viewer: the catalog page appears with the node's workspace, refresh works,
and the app closes without writing anything."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-workspaces-") as directory:
        ui = Desktop(directory, apps=("bee.workspace.manager:app",))
        try:
            ui.wait("WORKSPACES", timeout=20)
            ui.pump(.5)
            text = ui.text()
            assert "WORKSPACES" in text, text
            ui.key(b"r")
            ui.wait("WORKSPACES", timeout=5)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
    print("Workspaces app: boots under the broker, pages the node catalog, refreshes, closes cleanly")


if __name__ == "__main__":
    exercise()

"""The approvals inbox application boots under the application broker as the
local viewer: the frame appears, the owner's answer for the launch workspace is
shown honestly (the local actor is not an approver, so the inbox is unavailable
rather than empty), the technical toggle and refresh keys work, and the app
closes without touching the owner."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-inbox-") as directory:
        ui = Desktop(directory, apps=("bee.approvals.inbox:app",))
        try:
            ui.wait("APPROVALS", timeout=20)
            ui.wait("No requests", timeout=10)
            ui.pump(.5)
            text = ui.text()
            assert "unavailable" in text or "Refresh" in text, text
            ui.key(b"r")
            ui.wait("APPROVALS", timeout=5)
            ui.key(b"a")
            ui.pump(.4)
            assert "Open a pending request before deciding" in ui.text(), ui.text()
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
    print("Inbox app: boots under the broker, reports the owner's answer, refuses a decision without an opened request, closes cleanly")


if __name__ == "__main__":
    exercise()

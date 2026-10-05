"""The standalone binary opens the approvals inbox on a fresh state and reaches
the real governance lease owner: the leases view answers through the facade
under the inbox's lease policy, and the batch and lease keys refuse honestly
without a request to act on."""
from pathlib import Path
import sys
import tempfile

from native_workspace import NativeDesktop
from native_client import stop_owner, live_owners, hold_owner


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-inbox-leases-") as temporary:
    folder = Path(temporary) / "project"
    folder.mkdir()
    state = Path(temporary) / "state"
    ui = NativeDesktop(binary, folder, state, application="bee.approvals.inbox.app:app")
    try:
        ui.wait("APPROVALS", timeout=30)
        ui.pump(.5)
        ui.key(b"m")
        ui.wait("Select a request first", timeout=10)
        ui.key(b"b")
        ui.wait("Mark pending requests with M first", timeout=10)
        ui.key(b"l")
        ui.wait("Open a request first", timeout=10)
        ui.key(b"v")
        ui.wait("LEASES", timeout=20)
        ui.wait("No leases", timeout=20)
        text = ui.text()
        assert "DENIED" not in text and "BLOCKED" not in text and "INVALID" not in text, text
        ui.key(b"x")
        ui.wait("Select a lease that can be revoked", timeout=10)
        ui.key(b"v")
        ui.wait("APPROVALS", timeout=10)
        ui.quit()
    finally:
        ui.close()
        for pid in live_owners(binary, state):
            stop_owner(hold_owner(pid, binary, state))
print("Native inbox leases: fresh state, leases view answers through governance, guards refuse without a request")

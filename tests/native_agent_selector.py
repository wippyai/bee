"""Source-free public `bee agent`: empty picker, presenter rejoin and no work."""
from pathlib import Path
import sqlite3
import sys
import tempfile
import time

from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner, live_owners, owner_pidfd

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-agent-") as temporary:
    folder = Path(temporary) / "project"
    folder.mkdir()
    state = Path(temporary) / "state"
    ui = NativeDesktop(binary, folder, state, arguments=("agent",))
    owner = None
    try:
        ui.wait("No agent profiles", timeout=20)
        owner = owner_handle(ui, binary, state)
        ui.key(b"r")
        ui.wait("No agent profiles")
        ui.key(b"\x1b[24~")
        ui.wait("No agent profiles")
        ui.key(b"\x1b")
        deadline = time.monotonic() + 3
        while "No agent profiles" in ui.text() and time.monotonic() < deadline:
            ui.pump(.05)
        assert "No agent profiles" not in ui.text(), "Escape did not close the picker"
        assert ui.process.poll() is None, "Closing Agent exited the desktop"
        elapsed = ui.quit()
    finally:
        ui.close()
        stop_owner(owner)
        for pid in live_owners(binary, state):
            stop_owner(owner_pidfd(pid, binary, state))
    database = state / "threads.db"
    assert database.is_file(), "Native launch did not initialize its selected store"
    connection = sqlite3.connect(database)
    try:
        for table in ("bee_thread_heads", "bee_thread_actions", "bee_thread_attempts"):
            assert connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0, (
                f"Opening an empty Agent picker created work in {table}")
    finally:
        connection.close()
print(f"Native bee agent: public command, empty picker, F12, close without work; detach {elapsed:.3f}s")

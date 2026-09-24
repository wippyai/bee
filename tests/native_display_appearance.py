"""Real public clients persist display choices without changing their sibling."""
import sqlite3
import sys
import tempfile
import time
from pathlib import Path
from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner
from workspace import classic_workspace, client_layout

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-display-appearance-") as temporary:
    root = Path(temporary)
    state = root / "state"
    clients = []
    owner = None
    def read_layouts():
        workspace_id = classic_workspace(state / "workspace.db")
        database = state / "workspace.db.client"
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            desktops = [row[0] for row in connection.execute("SELECT client_id FROM client_desktops ORDER BY client_id")]
        finally:
            connection.close()
        primary = client_layout(database, workspace_id)[1]
        others = [client_layout(database, workspace_id, desktop)[1] for desktop in desktops]
        return primary, others
    def await_mode(mode, theme):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            for ui in clients:
                ui.pump(.03)
            primary, others = read_layouts()
            if primary["appearance_mode"] == mode and primary["preferences"]["theme"] == theme:
                assert len(others) == 1
                assert others[0]["appearance_mode"] == "inherit", others
                assert others[0]["preferences"]["theme"] == "honey", others
                return
        raise AssertionError((primary, others))
    try:
        first = NativeDesktop(binary, root, state)
        clients.append(first)
        first.wait(" BEE ", timeout=15)
        owner = owner_handle(first, binary, state)
        first.open_start()
        first.choose("Settings")
        first.wait("BEE SETTINGS")
        second = NativeDesktop(binary, root, state)
        clients.append(second)
        second.wait(" BEE ", timeout=15)
        second.open_start()
        second.choose("Settings")
        second.wait("BEE SETTINGS")
        await_mode("inherit", "honey")
        first.key(b"\x1b[F")
        first.wait("Windows Classic")
        await_mode("custom", "classic")
        first.key(b"\x1b[24~")
        first.wait("BEE SETTINGS")
        await_mode("custom", "classic")
        first.choose("Use node default")
        await_mode("inherit", "honey")
        for ui in reversed(clients):
            ui.quit()
        print("Public displays: primary inherits, custom Classic stays local through F12, reset resumes Honey; sibling remains inherit/Honey")
    finally:
        for ui in reversed(clients):
            ui.close()
        stop_owner(owner)

"""Two-binary state upgrade regression; never uses recover or user stores.

The predecessor is deliberately launched through its historical CLI. This is a
test fixture for an installed old binary, not compatibility in Bee's current
command surface.
"""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import pyte
from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner
from tui_smoke import Desktop
from workspace import classic_workspace


class PreviousDesktop(Desktop):
    def __init__(self, binary, folder, state, application):
        self.master, slave = pty.openpty()
        self.width, self.height = 100, 30
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.pending_output = ""
        args = [str(binary), "--state-dir", str(state), "run", application]
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("BEE_") and key != "USER"}
        env.update(TERM="xterm-256color", HOME=str(folder),
                   PATH=f"{folder}/bin:/usr/bin:/bin", XDG_CONFIG_HOME=str(folder / ".config"))
        self.process = subprocess.Popen(args, cwd=folder, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=env)
        os.close(slave)


def migrations(state):
    with sqlite3.connect(f"file:{state / 'workspace.db'}?mode=ro", uri=True) as db:
        return db.execute("SELECT id,name,checksum FROM workspace_schema_migrations ORDER BY id").fetchall()


def previous_identity(state):
    """The predecessor may predate the node catalog and keep its identity in the singleton table."""
    with sqlite3.connect(f"file:{state / 'workspace.db'}?mode=ro", uri=True) as db:
        catalog = db.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='workspaces'").fetchone()[0]
        if not catalog:
            rows = db.execute("SELECT workspace_id FROM workspace_identity").fetchall()
            assert len(rows) == 1, "Previous binary did not persist a workspace identity"
            return rows[0][0]
    return classic_workspace(state / "workspace.db")


def run(previous, current, added_application=None):
    with tempfile.TemporaryDirectory(prefix="bee-native-upgrade-") as temporary:
        folder = Path(temporary)
        state = folder / "state"
        old = PreviousDesktop(previous, folder, state, "bee.settings:app")
        try:
            old.wait("Settings")
            old.wait("Theme: Honey")
            old.key(b"\x1b[C")
            old.wait("Theme: Ocean")
            if added_application:
                old.open_start()
                old.choose("Tools")
                assert added_application not in old.text(), f"Previous binary already has {added_application}"
                old.key(b"\x1b")
                old.key(b"\x1b")
            old.quit()
        finally:
            old.close()
        before = previous_identity(state), migrations(state)
        assert before[1], "Previous binary did not persist its migration ledger"
        owner = None
        new = NativeDesktop(current, folder, state)
        try:
            new.wait("Settings")
            owner = owner_handle(new, current, state)
            new.wait("Theme: Ocean")
            new.open_start()
            new.choose("Tools")
            new.wait(added_application or "Hive Manager")
            assert "Test Status" not in new.text(), new.text()
            new.key(b"\x1b")
            new.key(b"\x1b")
            new.quit()
        finally:
            new.close()
            stop_owner(owner)
        after = classic_workspace(state / "workspace.db"), migrations(state)
        assert after[0] == before[0], "Binary upgrade changed workspace identity"
        assert after[1][:len(before[1])] == before[1], "Binary upgrade rewrote applied migrations"
    print("Native upgrade: retained Settings and workspace identity, unchanged applied migrations")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: native_upgrade.py PREVIOUS_BEE CURRENT_BEE [ADDED_APPLICATION]")
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3] if len(sys.argv) == 4 else None)

"""Two-binary base-code upgrade regression; never uses --base or user stores.

Use an older Bee without Hive Manager as the first binary and the current build
as the second. This proves base selection and workspace identity preservation;
authorized registry-overlay preservation remains a separate required gate.
"""
from pathlib import Path
import sqlite3
import sys
import tempfile
from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner


def identity(state):
    with sqlite3.connect(f"file:{state / 'workspace.db'}?mode=ro", uri=True) as db:
        return (db.execute("SELECT * FROM workspace_identity").fetchall(),
                db.execute("SELECT id,name,checksum FROM workspace_schema_migrations ORDER BY id").fetchall())


def run(previous, current):
    with tempfile.TemporaryDirectory(prefix="bee-native-upgrade-") as temporary:
        folder = Path(temporary)
        state = folder / "state"
        old = NativeDesktop(previous, folder, state, "bee.settings:app")
        try:
            old.wait("Settings")
            old.wait("Theme: Honey")
            old.key(b"\x1b[C")
            old.wait("Theme: Ocean")
            old.open_start()
            old.choose("Tools")
            assert "Hive Manager" not in old.text(), "Previous binary must predate Hive Manager"
            old.key(b"\x1b")
            old.key(b"\x1b")
            old.quit()
        finally:
            old.close()
        before = identity(state)
        assert len(before[0]) == 1, "Previous binary did not persist a workspace identity"
        assert before[1], "Previous binary did not persist its migration ledger"
        owner = None
        new = NativeDesktop(current, folder, state)
        try:
            new.wait("Settings")
            owner = owner_handle(new, current, state)
            new.wait("Theme: Ocean")
            new.open_start()
            new.choose("Tools")
            new.wait("Hive Manager")
            assert "Test Status" not in new.text(), new.text()
            new.key(b"\x1b")
            new.key(b"\x1b")
            new.quit()
        finally:
            new.close()
            stop_owner(owner)
        after = identity(state)
        assert after[0] == before[0], "Binary upgrade changed workspace identity"
        assert after[1][:len(before[1])] == before[1], "Binary upgrade rewrote applied migrations"
    print("Native base upgrade: fresh embedded catalog, retained Settings and workspace identity, unchanged applied migrations")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: native_upgrade.py PREVIOUS_BEE CURRENT_BEE")
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())

"""Boot main's saved desktop with the nested-name source and retain its windows."""
import io
import json
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME  # noqa: E402

# The main revision from which this naming branch started. Archive it; never
# replace the working tree or copy a developer's private state.
BASE = "ddc2694acf065d5b4253cc13f231dd1a65e92dab"
RENAMED = {
    "bee.inbox:app": "bee.approvals.inbox:app",
    "bee.overlays:app": "bee.gov.overlays:app",
}
OLD = {"bee.settings:app", *RENAMED}
NEW = {"bee.settings:app", *RENAMED.values()}


def saved(database):
    with sqlite3.connect(database) as db:
        row = db.execute("SELECT workspace_id, root_ref FROM workspaces").fetchone()
        state = json.loads(db.execute("SELECT value FROM workspace_state").fetchone()[0])
        ledger = db.execute("SELECT id FROM workspace_schema_migrations ORDER BY id").fetchall()
    return row, {app["definition_id"]: (app["id"], app["instance_id"])
                 for app in state["applications"]}, [id_[0] for id_ in ledger]


def layout(database):
    with sqlite3.connect(database) as db:
        row = db.execute("SELECT value FROM client_layouts ORDER BY generation DESC LIMIT 1").fetchone()
    assert row, "the desktop did not save its layout"
    value = json.loads(row[0])
    return {(target["workspace_id"], target["instance_id"], target["view_id"])
            for target in value["targets"]}


def main():
    with tempfile.TemporaryDirectory(prefix="names-upgrade-", dir=ROOT / ".wippy") as temporary:
        root = Path(temporary)
        old_source = root / "main"
        old_source.mkdir()
        archive = subprocess.check_output(["git", "archive", BASE], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            bundle.extractall(old_source, filter="data")
        subprocess.run([str(RUNTIME), "install"], cwd=old_source, check=True,
                       stdout=subprocess.DEVNULL)
        state = root / "state"
        state.mkdir()
        old = Desktop(state, project=old_source, apps=("bee.settings:app",), command_name="bee-app")
        try:
            old.wait("Settings", timeout=40)
            old.open_start()
            old.choose("Tools")
            old.choose("Approvals")
            old.wait("Approvals", timeout=10)
            old.open_start()
            old.choose("Tools")
            old.choose("Overlays")
            old.wait("╭─ Overlays", timeout=10)
            old.quit()
        finally:
            old.close()
        before_root, before_apps, old_ledger = saved(state / "workspace.db")
        before_layout = layout(state / "workspace.db.client")
        assert set(before_apps) == OLD, before_apps
        assert before_root[1] == "bee.environment:workspace_root", before_root
        assert old_ledger == list(range(1, 9)), old_ledger

        renamed = Desktop(state)
        try:
            renamed.wait("Settings", timeout=40)
            renamed.open_start()
            renamed.choose("Tools")
            renamed.choose("Overlays")
            renamed.wait("╭─ Overlays", timeout=10)
            renamed.open_start()
            renamed.choose("Tools")
            renamed.choose("Approvals")
            renamed.wait("Approvals", timeout=10)
            renamed.quit()
        finally:
            renamed.close()
        after_root, after_apps, new_ledger = saved(state / "workspace.db")
        after_layout = layout(state / "workspace.db.client")
        assert after_root == (before_root[0], "bee.env:workspace_root"), after_root
        assert set(after_apps) == NEW, after_apps
        assert after_apps["bee.settings:app"] == before_apps["bee.settings:app"]
        for old_id, new_id in RENAMED.items():
            assert after_apps[new_id] == before_apps[old_id]
        assert after_layout == before_layout, (before_layout, after_layout)
        assert new_ledger == list(range(1, 10)), new_ledger
        print("Main state upgraded: Settings, Approvals, and Overlays windows retained their identities and layout")


if __name__ == "__main__":
    main()

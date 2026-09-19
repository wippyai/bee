"""Project-node executable acceptance; does not claim Hive convergence."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import sqlite3
import subprocess
import sys
import tempfile

from native_client import owner_handle, stop_owner
from native_workspace import NativeDesktop, STATE_ENVIRONMENT


def migration_ledgers(state, databases):
    ledgers = {}
    for relative in databases:
        path = state / relative
        with sqlite3.connect(path) as database:
            tables = [row[0] for row in database.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%schema_migrations' ORDER BY name")]
            for table in tables:
                ledgers[(relative, table)] = database.execute(
                    f'SELECT * FROM "{table}" ORDER BY 1').fetchall()
    return ledgers


def workspace_identity(state, workspace_db):
    with sqlite3.connect(state / workspace_db) as database:
        row = database.execute("SELECT workspace_id FROM workspace_identity WHERE singleton=1").fetchone()
    assert row and row[0], "workspace identity is absent"
    return row[0]


def launch_environment(home):
    environment = {key: value for key, value in os.environ.items() if key not in STATE_ENVIRONMENT}
    environment.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
    return environment


def run_legacy_upgrade(binary, previous, databases, bindings):
    with tempfile.TemporaryDirectory(prefix="bee-project-upgrade-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        legacy_project = root / "legacy-project"
        other_project = root / "other-project"
        legacy_project.mkdir()
        other_project.mkdir()
        legacy_state = home / ".config/bee"
        hashed_legacy = legacy_state / "projects" / hashlib.sha256(str(legacy_project.resolve()).encode()).hexdigest()
        hashed_other = legacy_state / "projects" / hashlib.sha256(str(other_project.resolve()).encode()).hexdigest()

        old_view = NativeDesktop(previous, legacy_project, None, arguments=("terminal",), home=home)
        old_owner = None
        try:
            old_view.wait(" BEE ", timeout=30)
            old_owner = owner_handle(old_view, previous, legacy_state)
            old_view.wait("Terminal", timeout=10)
            blocked = subprocess.run([str(binary), "client"], cwd=legacy_project,
                                     env=launch_environment(home), capture_output=True,
                                     text=True, timeout=10)
            assert blocked.returncode != 0, "candidate bound legacy state while its owner was running"
            assert "legacy Bee is running" in blocked.stderr + blocked.stdout, blocked
            assert not (legacy_state / "project-state.json").exists(), "refused cutover published a receipt"
        finally:
            old_view.close()
            if old_owner is not None:
                stop_owner(old_owner)

        before_identity = workspace_identity(legacy_state, bindings["BEE_WORKSPACE_DB"])
        before_ledgers = migration_ledgers(legacy_state, databases)
        hive_authority = legacy_state / "local-hive/authority.pem"
        assert hive_authority.is_file(), "legacy launch did not create machine Hive authority"
        authority_before = hive_authority.read_bytes()

        views, owners = [], []
        try:
            upgraded = NativeDesktop(binary, legacy_project, None, arguments=("terminal",), home=home)
            views.append(upgraded)
            upgraded.wait(" BEE ", timeout=30)
            owners.append(owner_handle(upgraded, binary, legacy_state))
            upgraded.wait("Terminal", timeout=10)
            receipt = json.loads((legacy_state / "project-state.json").read_text())
            assert receipt == {"version": 1, "mode": "legacy-root",
                               "project_dir": str(legacy_project.resolve()),
                               "state_dir": str(legacy_state)}, receipt
            assert not list(hashed_legacy.glob("*.db*")), "bound project duplicated legacy databases"
            assert workspace_identity(legacy_state, bindings["BEE_WORKSPACE_DB"]) == before_identity
            after_ledgers = migration_ledgers(legacy_state, databases)
            for key, rows in before_ledgers.items():
                assert after_ledgers[key][:len(rows)] == rows, f"upgrade rewrote migration ledger {key}"

            other = NativeDesktop(binary, other_project, None, arguments=("terminal",), home=home)
            views.append(other)
            other.wait(" BEE ", timeout=30)
            owners.append(owner_handle(other, binary, hashed_other))
            other.wait("Terminal", timeout=10)
            assert workspace_identity(hashed_other, bindings["BEE_WORKSPACE_DB"]) != before_identity
            assert json.loads((legacy_state / "project-state.json").read_text()) == receipt
        finally:
            for view in reversed(views):
                view.close()
            for owner in owners:
                stop_owner(owner)

        rollback = NativeDesktop(previous, legacy_project, None, arguments=("terminal",), home=home)
        rollback_owner = None
        try:
            rollback.wait(" BEE ", timeout=30)
            rollback_owner = owner_handle(rollback, previous, legacy_state)
            rollback.wait("Terminal", timeout=10)
            assert workspace_identity(legacy_state, bindings["BEE_WORKSPACE_DB"]) == before_identity
            assert hive_authority.read_bytes() == authority_before, "project cutover replaced Hive authority"
        finally:
            rollback.close()
            if rollback_owner is not None:
                stop_owner(rollback_owner)

    print("Project upgrade: running-owner refusal, one durable legacy-root binding, unchanged workspace and migration history, isolated second project, shared Hive authority and old-binary rollback pass")


def run(binary, previous=None):
    provenance = json.loads(Path(str(binary) + ".provenance.json").read_text())
    bindings = provenance["manifest"]["application"]["data"]
    databases = [path for name, path in bindings.items() if name.endswith("_DB")]
    databases += [bindings["BEE_WORKSPACE_DB"] + ".client", "registry.db"]
    def check_stores(state):
        for relative in databases:
            path = state / relative
            assert path.is_file(), f"missing state-bound database: {path}"
            assert path.read_bytes()[:16] == b"SQLite format 3\0", f"not a SQLite database: {path}"
        assert (state / bindings["BEE_PLACEMENT_ROOT"]).is_dir(), "placement root escaped state"
    with tempfile.TemporaryDirectory(prefix="bee-project-nodes-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        folders = [root / name for name in ("alpha", "beta", "empty")]
        for folder in folders:
            folder.mkdir()
        states = [home / ".config/bee/projects" / hashlib.sha256(str(folder.resolve()).encode()).hexdigest() for folder in folders]
        views, owners = [], []
        try:
            for index in range(2):
                view = NativeDesktop(binary, folders[index], None, arguments=("terminal",), home=home)
                views.append(view)
                view.wait(" BEE ", timeout=30)
                owners.append(owner_handle(view, binary, states[index]))
                view.wait("Terminal", timeout=10)
                view.key(("test \"$PWD\" = " + shlex.quote(str(folders[index])) +
                          f" && printf 'PROJECT_{index}_%s\\n' CORRECT\r").encode())
                view.wait(f"PROJECT_{index}_CORRECT", timeout=10)
                assert b"Starting Bee" in view.raw, "different project reused an existing node"
            for state in states[:2]:
                check_stores(state)
            for relative in databases:
                assert not os.path.samefile(states[0] / relative, states[1] / relative), f"projects share {relative}"
            for folder in folders:
                assert not list(folder.rglob("*.db*")), "database escaped selected project state"
            descriptions = [json.loads((state / "local-mesh/mesh-owner.json").read_text()) for state in states[:2]]
            assert descriptions[0]["node"] != descriptions[1]["node"], "project node names collide"
            assert descriptions[0]["execution"] != descriptions[1]["execution"], "project executions collide"
            before = set(states[0].glob("owner-*.log"))
            third = NativeDesktop(binary, folders[0], None, arguments=("terminal",), home=home)
            views.append(third)
            third.wait(" BEE ", timeout=20)
            third.wait("Terminal", timeout=10)
            assert b"Connecting to Hive" in third.raw, "same folder did not select a display"
            assert set(states[0].glob("owner-*.log")) == before, "same folder started another owner"
            third.key(("test \"$PWD\" = " + shlex.quote(str(folders[0])) + " && printf 'REUSED_%s\\n' PROJECT\r").encode())
            third.wait("REUSED_PROJECT", timeout=10)
            client = NativeDesktop(binary, folders[0], None, arguments=("client",), home=home)
            views.append(client)
            client.wait(" BEE ", timeout=20)
            assert set(states[0].glob("owner-*.log")) == before, "explicit client started another owner"
            absent = subprocess.run([str(binary), "client"], cwd=folders[2], env=launch_environment(home),
                                    capture_output=True, text=True, timeout=10)
            assert absent.returncode != 0 and "No running Bee for this project" in absent.stderr + absent.stdout, absent
            assert not list(states[2].glob("owner-*.log")) and not list(states[2].glob("*.db"))
            explicit_state = root / "explicit-state"
            explicit = NativeDesktop(binary, folders[2], explicit_state, arguments=("terminal",), home=home)
            views.append(explicit)
            explicit.wait(" BEE ", timeout=30)
            owners.append(owner_handle(explicit, binary, explicit_state))
            explicit.wait("Terminal", timeout=10)
            check_stores(explicit_state)
            assert not list(states[2].glob("*.db*")), "explicit state also created default databases"
            assert not list(folders[2].rglob("*.db*")), "explicit state wrote databases in project folder"
            explicit.key(("test \"$PWD\" = " + shlex.quote(str(folders[2])) + " && printf 'EXPLICIT_%s\\n' CORRECT\r").encode())
            explicit.wait("EXPLICIT_CORRECT", timeout=10)
        finally:
            for view in reversed(views):
                view.close()
            for owner in owners:
                stop_owner(owner)
    print("Project executable: distinct folder nodes, terminal cwd, same-folder display reuse, explicit client refusal, every manifested DB plus client/registry isolation and explicit state override; Hive joining unverified")
    if previous is not None:
        run_legacy_upgrade(binary, previous, databases, bindings)


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None)

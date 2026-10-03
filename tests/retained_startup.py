"""Prove retained app identity repair and record isolation with non-credential copies."""
import argparse
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tarfile

from native_client import owner_handle
from native_workspace import NativeDesktop
from workspace import RUNTIME

ROOT = Path(__file__).resolve().parents[1]
COPY_NAMES = ("gateway", "governance", "node", "placement", "resources", "sync", "threads", "workspace")


def prepare(folder, source=None):
    folder.mkdir(parents=True)
    state, home = folder / "state", folder / "home"
    state.mkdir(mode=0o700)
    home.mkdir(mode=0o700)
    if source:
        for name in COPY_NAMES:
            with sqlite3.connect(f"file:{source / f'{name}.db'}?mode=ro", uri=True) as prior:
                with sqlite3.connect(state / f"{name}.db") as copied:
                    prior.backup(copied)
        with sqlite3.connect(state / "workspace.db") as db:
            displays = db.execute("SELECT DISTINCT display_id FROM workspace_display_assignments").fetchall()
        assert len(displays) == 1, "copy fixture needs its omitted client catalog reconstructed explicitly"
        client = folder.parent / "fresh/state/workspace.db.client"
        with sqlite3.connect(f"file:{client}?mode=ro", uri=True) as prior:
            with sqlite3.connect(state / "workspace.db.client") as copied:
                prior.backup(copied)
                copied.execute("UPDATE client_state SET client_id = ?", displays[0])
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
           "TERM": "xterm-256color", "LANG": "C.UTF-8", "TMPDIR": str(folder)}
    for name in (*COPY_NAMES, "approvals", "credentials"):
        env[f"BEE_{name.upper()}_DB"] = str(state / f"{name}.db")
    return state, env


def applications(state):
    with sqlite3.connect(f"file:{state / 'workspace.db'}?mode=ro", uri=True) as db:
        return [item for row in db.execute("SELECT value FROM workspace_state")
                for item in json.loads(row[0])["applications"]]


def aliases(state):
    with sqlite3.connect(f"file:{state / 'threads.db'}?mode=ro", uri=True) as db:
        return {row[0]: row[1:] for row in db.execute(
            "SELECT instance, definition_id, stable, created_at FROM bee_thread_app_alias")}


def stop(binary, folder, state, env, owner):
    result = subprocess.run([str(binary), "--state", str(state), "stop"], cwd=folder, env=env,
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    assert owner.exited(timeout=30), "stop acknowledged before owner EXIT"
    owner.close()
    assert "Bee stopped" in result.stdout, result.stdout
    stale = subprocess.run([str(binary), "--state", str(state), "stop"], cwd=folder, env=env,
                           capture_output=True, text=True, timeout=30)
    assert stale.returncode == 0, stale.stderr
    assert "Bee was not running (stale owner record cleared)" in stale.stdout, stale.stdout


def desktop(binary, folder, state, env, check):
    ui = NativeDesktop(binary, folder, state, environment=env)
    owner = None
    try:
        ui.wait(" BEE ", timeout=120)
        owner = owner_handle(ui, binary, state)
        ui.resize(150, 42)
        check(ui)
        ui.quit()
        stop(binary, folder, state, env, owner)
        owner = None
    finally:
        ui.close()
        if owner is not None:
            try:
                owner.stop()
            finally:
                owner.close()


def restore(ui):
    ui.open_start()
    ui.choose("Apps")
    ui.choose("Advanced")
    ui.choose("Overlays")
    ui.wait("OVERLAYS", timeout=60)
    ui.open_start()
    ui.choose("Needs you")
    ui.wait("NEEDS YOU", timeout=60)


def retained(binary, source, root):
    folder = root / "copied-owner"
    state, env = prepare(folder, source)
    before, prior = applications(state), aliases(state)
    assert len(before) == 2, "owner copy fixture changed; inspect its non-credential checkpoint identities"
    desktop(binary, folder, state, env, restore)
    after, current = applications(state), aliases(state)
    for record in before:
        assert any(row["instance_id"] == record["instance_id"] and row["id"] == record["id"]
                   and row["definition_id"] == record["definition_id"] for row in after), "retained application identity changed"
        actor = next(key for key in current if key.endswith(":" + record["instance_id"]))
        assert current[actor][0] == record["definition_id"], "retained attestation still names prior app"
        assert current[actor][2] == prior[actor][2], "attestation creation time changed"
        print(f"Restored retained instance: {record['definition_id']} (original instance/view and attestation preserved)")
    with sqlite3.connect(f"file:{state / 'threads.db'}?mode=ro", uri=True) as db:
        assert db.execute("SELECT id FROM bee_thread_definition_migrations ORDER BY id").fetchall() == [(1,), (2,)]
    desktop(binary, folder, state, env, restore)
    print("Copied owner state restart and stale-owner stop: pass")


def invalid(binary, source, root):
    folder = root / "invalid-retained"
    state, env = prepare(folder, source)
    records = applications(state)
    inbox = next(row for row in records if row["definition_id"] == "bee.approvals.inbox.app:app")
    with sqlite3.connect(state / "threads.db") as db:
        stable, workspace = db.execute("SELECT stable, workspace_id FROM bee_thread_app_alias WHERE definition_id = 'bee.console.app:app' LIMIT 1").fetchone()
        db.execute("UPDATE bee_thread_app_alias SET stable = ?, definition_id = 'bee.console.app:app' WHERE instance = ?",
                   (stable, "bee.application:" + workspace + ":" + inbox["instance_id"]))
    with sqlite3.connect(state / "workspace.db") as db:
        for key, encoded in db.execute("SELECT workspace_id, value FROM workspace_state").fetchall():
            checkpoint = json.loads(encoded)
            checkpoint["applications"].append({**inbox, "id": "retained-missing", "instance_id": "retained-missing",
                                               "definition_id": "removed.app:app", "restart_policy": "automatic", "window": None})
            db.execute("UPDATE workspace_state SET value = ? WHERE workspace_id = ?", (json.dumps(checkpoint), key))
    def inspect(ui):
        ui.open_start(); ui.choose("Apps"); ui.choose("Restoration failures"); ui.key(b"\r")
        ui.wait("application instance is attested for another app", timeout=60)
        ui.key(b"\t\r")
        ui.wait_until(lambda: "Application restoration failed" not in ui.text(), "acknowledged restoration notice", timeout=60)
        ui.open_start(); ui.choose("Needs you"); ui.choose("retained-missing")
        ui.wait("Retained application is not admitted: removed.app:app", timeout=60)
        ui.key(b"\t\r")
        ui.wait_until(lambda: "Application restoration failed" not in ui.text(), "acknowledged unavailable-app notice", timeout=60)
        ui.open_start(); ui.choose("Apps"); ui.choose("Advanced"); ui.choose("Overlays")
        ui.wait("OVERLAYS", timeout=60)
    desktop(binary, folder, state, env, inspect)
    after = applications(state)
    assert any(row["instance_id"] == inbox["instance_id"] for row in after), "rejected record was deleted"
    assert any(row["instance_id"] == "retained-missing" for row in after), "unavailable record was deleted"
    messages = "\n".join(line for log in state.glob("owner-*.log") for line in log.read_text().splitlines()
                         if "Retained application restoration failed" in line)
    assert "application instance is attested for another app" in messages
    assert "Retained application is not admitted: removed.app:app" in messages
    print("Invalid retained aliases and unavailable app: exact desktop/startup-log errors, saved records retained, independent app restored")


def origin_restart(binary, root):
    folder = root / "origin-main"
    state, env = prepare(folder)
    project = folder / "source"
    project.mkdir()
    commit = subprocess.check_output(["git", "rev-parse", "origin/main"], cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(["git", "archive", commit], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(project, filter="data")
    subprocess.run([sys.executable, str(ROOT / "build/dependency_artifacts.py"), str(project / "wippy.lock"),
                    str(ROOT / ".wippy/vendor"), str(project / ".wippy/vendor")], check=True)
    ui = NativeDesktop(RUNTIME, project, None, environment=env, arguments=(
        "run", "bee", "bee.settings.app:app", "--host", "bee:terminal",
        "--set", f"registry.history_path={state / 'source-registry.db'}"))
    try:
        ui.wait("Settings", timeout=120)
        ui.wait("Theme", timeout=60)
        ui.quit()
    finally:
        ui.close()
    before = applications(state)
    assert before, "origin/main did not retain Settings"
    desktop(binary, folder, state, env, lambda ui: ui.wait("Theme", timeout=60))
    after = applications(state)
    for record in before:
        assert any(all(row[key] == record[key] for key in ("id", "instance_id", "definition_id"))
                   for row in after), "origin/main retained identity changed"
    desktop(binary, folder, state, env, lambda ui: ui.wait("Theme", timeout=60))
    print(f"origin/main {commit[:12]} source-created state: standalone restore and second restart pass")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--copy", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    options = parser.parse_args()
    binary, source, root = options.binary.resolve(), options.copy.resolve(), options.evidence.resolve()
    assert ROOT / ".wippy" in root.parents, "evidence must stay under this worktree's .wippy"
    assert not root.exists(), "retain existing proof state; select a new evidence directory"
    folder = root / "fresh"
    state, env = prepare(folder)
    desktop(binary, folder, state, env, lambda ui: ui.wait("SESSIONS", timeout=60))
    print("Fresh standalone desktop and stale-owner stop: pass")
    retained(binary, source, root)
    invalid(binary, source, root)
    origin_restart(binary, root)


if __name__ == "__main__":
    main()

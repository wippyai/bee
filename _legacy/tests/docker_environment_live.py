"""Opt-in native desktop Docker admission proof; no credential reads."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time

from native_workspace import NativeDesktop, STATE_ENVIRONMENT

ROOT = Path(__file__).resolve().parents[1]
TITLE = "Docker Claude acceptance"


def rows(state, name, query):
    with sqlite3.connect("file:" + str(state / (name + ".db")) + "?mode=ro", uri=True) as database:
        database.row_factory = sqlite3.Row
        return [dict(row) for row in database.execute(query)]


def wait_for(ui, predicate, detail, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ui.pump(.5)
        if predicate():
            return
    raise AssertionError(detail)


def select(ui, label):
    for _ in range(25):
        ui.key(b"\x1b[A")
    for _ in range(70):
        if "›" + label in ui.text():
            return
        ui.key(b"\x1b[B")
    raise AssertionError("Catalog item absent: " + label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/bee")
    parser.add_argument("--decision", choices=("approve", "deny"), default="approve")
    args = parser.parse_args()
    base = args.evidence.resolve()
    base.mkdir(parents=True, exist_ok=True)
    project, state = base / "project", base / "state"
    project.mkdir(exist_ok=True)
    assert not state.exists(), "Acceptance requires a fresh state directory"
    binary = args.binary.resolve()
    env = {key: value for key, value in os.environ.items() if key not in STATE_ENVIRONMENT | {"BEE_RUNTIME", "USER"}}
    env.update(TERM="xterm-256color", TMPDIR=str(ROOT / ".wippy/tmp"))
    ui = None
    try:
        ui = NativeDesktop(binary, project, state, arguments=("agent",), environment=env)
        ui.resize(180, 45)
        ui.wait("SESSIONS", timeout=90)
        ui.key(b"n")
        ui.wait("NEW SESSION", timeout=30)
        ui.wait_until(lambda: "Loading agents" not in ui.text(), "catalog", timeout=90)
        select(ui, "Claude Code")
        ui.key(b"n")
        ui.wait("CUSTOMIZE COPY", timeout=45)
        for _ in range(35):
            ui.key(b"\x7f")
        ui.key(TITLE.encode())
        for _ in range(15):
            if "›Placement:" in ui.text():
                break
            ui.key(b"\t")
        else:
            raise AssertionError("Placement form absent")
        ui.key(b"\x1b[C")
        ui.key(b"\x1b[C")
        ui.pump(1)
        assert "bee.placement.docker.profiles:coding" in ui.text(), ui.text()
        (base / "profile.txt").write_text(ui.text())
        ui.key(b"\x13")
        ui.wait("NEW SESSION", timeout=45)
        ui.wait(TITLE, timeout=90)
        select(ui, TITLE)
        ui.key(b"\r")
        ui.wait("idle", timeout=45)
        ui.key(b"Reply only with native-docker-profile-ok.\r")
        wait_for(ui, lambda: (state / "approvals.db").exists() and bool(rows(state, "approvals", "SELECT approval_id FROM bee_approval_requests WHERE policy='docker-environment'")), "No first-use approval", 60)
        ui.wait("Preparing Docker network and gateway", timeout=30)
        (base / "progress.txt").write_text(ui.text())
        ui.open_start()
        ui.choose("Needs you")
        ui.wait("NEEDS YOU", timeout=30)
        ui.wait("Allow Bee to create", timeout=30)
        ui.key(b"j")
        ui.key(b"o")
        (base / "approval-before.txt").write_text(ui.text())
        ui.key(b"a" if args.decision == "approve" else b"d")
        ui.wait("Approve this request?" if args.decision == "approve" else "Deny this request?", timeout=20)
        ui.key(b"\t")
        ui.key(b"\r")
        ui.wait(("approved" if args.decision == "approve" else "denied") + " by bee.application:", timeout=30)
        (base / "approval-after.txt").write_text(ui.text())
        ui.key(b"\x1b")
        ui.key(b"\x1b\t")
        def completed(count):
            works = rows(state, "threads", "SELECT phase,result_json,uncertainty_json FROM bee_session_work ORDER BY sequence")
            if len(works) != count:
                return False
            if args.decision == "deny":
                return bool(works[-1]["uncertainty_json"]) or works[-1]["phase"] == "settled"
            assert not works[-1]["uncertainty_json"], works
            return works[-1]["phase"] == "settled"
        wait_for(ui, lambda: completed(1), "First Docker work did not finish")
        if args.decision == "approve":
            first = rows(state, "threads", "SELECT result_json FROM bee_session_work")[0]
            assert json.loads(first["result_json"])["state"] == "succeeded", first
            ui.key(b"Reply only with native-docker-reuse-ok.\r")
            wait_for(ui, lambda: completed(2), "Approved environment was not reused")
            results = rows(state, "threads", "SELECT result_json FROM bee_session_work ORDER BY sequence")
            assert all(json.loads(row["result_json"])["state"] == "succeeded" for row in results), results
            (base / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            wait_for(ui, lambda: all(row["cleanup_state"] == "complete" for row in rows(state, "placement", "SELECT cleanup_state FROM bee_placement_attempts")), "Containers did not finish cleanup", 45)
            (base / "final.txt").write_text(ui.text())
            ui.key(b"\x1b")
            ui.key(b"n")
            ui.wait("NEW SESSION", timeout=45)
            ui.wait(TITLE, timeout=90)
            select(ui, TITLE)
            ui.key(b"e")
            ui.wait("EDIT AGENT PROFILE", timeout=45)
            ui.key(b"\x12")
            ui.wait("Revoke Docker network and gateway access?", timeout=30)
            ui.key(b"\r")
            ui.wait("Docker network and gateway access revoked", timeout=45)
            (base / "revoked.txt").write_text(ui.text())
        else:
            works = rows(state, "threads", "SELECT phase,result_json,uncertainty_json FROM bee_session_work")
            assert "declined" in json.dumps(works), works
            assert not rows(state, "placement", "SELECT attempt_id FROM bee_placement_attempts")
            (base / "declined.txt").write_text(ui.text())
        approvals = rows(state, "approvals", "SELECT approval_id,state,decision,decider_id,consumer_id,consumed_at FROM bee_approval_requests WHERE policy='docker-environment'")
        assert len(approvals) == 1, approvals
        receipt = json.loads((state / "placement/images/environment.json").read_text())
        assert receipt["state"] == ("revoked" if args.decision == "approve" else "denied"), receipt
        (base / "admission-audit.json").write_text(json.dumps({"approvals": approvals, "receipt": receipt}, indent=2) + "\n")
        print("Docker first-use " + args.decision + " passed", flush=True)
    except Exception:
        if ui:
            (base / "error.txt").write_text(ui.text())
        raise
    finally:
        if ui:
            ui.close()
        subprocess.run([str(binary), "--state", str(state), "stop"], cwd=project, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=45, check=True)


if __name__ == "__main__":
    main()

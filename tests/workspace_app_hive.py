"""Carry an agent-built workspace application across Hive to a second node.

The source is the workspace-app-delivery journey: a managed agent authors
Tally, its person approves and applies it on node-1. The destination has no
activation profile for that source; only its shipped workspace-applications
rule admits the received overlay. The destination instantiates its own
profile and catalog, its own person approves the plan in Approvals, and it
installs its own grants: the application opens there, reads the
destination's workspace file and keeps its rows in the destination's own
database.
"""
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from agent_app_hive import bridge, prepare_destination  # noqa: E402
from app_journey import COLD_BOOT, apply_staged_in_ui, open_catalog_app  # noqa: E402
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, classic_workspace  # noqa: E402

SOURCE_NODE = "node-1"
GREETING = "hello from the destination"


def evidence_root():
    selected = os.environ.get("BEE_WORKSPACE_APP_HIVE_EVIDENCE")
    root = Path(selected).resolve() if selected else ROOT / ".wippy/evidence" / time.strftime("workspace-app-hive-%Y%m%d-%H%M%S")
    root.mkdir(parents=True, exist_ok=bool(selected))
    return root


def author_source(folder):
    environment = os.environ.copy()
    environment.update({"BEE_RUNTIME": str(RUNTIME), "BEE_WORKSPACE_APP_EVIDENCE": str(folder),
                        "BEE_WORKSPACE_APP_HIVE_SOURCE_NODE": SOURCE_NODE})
    subprocess.run(["python3", "tests/workspace_app_delivery.py"], cwd=ROOT, env=environment, check=True)
    authored = json.loads((folder / "authored.json").read_text())
    assert authored["admission"] == "rule" and authored["source_workspace"] == "tally", authored
    return authored


def exercise():
    evidence = evidence_root()
    source = evidence / "source"
    authored = author_source(source)
    os.environ["BEE_AGENT_APP_HIVE_SOURCE_PROJECT"] = str(source / "project")
    os.environ["BEE_AGENT_APP_HIVE_SOURCE_STATE"] = str(source)
    os.environ["BEE_AGENT_APP_HIVE_SOURCE_WORKSPACE"] = authored["workspace_id"]
    destination = evidence / "destination"
    workspace_id = prepare_destination(destination, evidence, SOURCE_NODE, explicit=False)
    (destination / "shared").mkdir()
    (destination / "shared" / "greeting.txt").write_text(GREETING)
    bridge(destination, workspace_id, source / "authored.json", evidence, applied=False)

    ui = Desktop(destination, project=destination)
    try:
        ui.wait("No applications open", timeout=COLD_BOOT)
        ui.pump(.5)
        apply_staged_in_ui(ui, {"workspace": authored["source_workspace"], "version": authored["published_version"],
                                "approval_policy": "workspace-application-delivery"},
                           destination, expected_capability=["Read owned threads",
                                                             "Read workspace files under shared",
                                                             "Use an isolated application database named tally"])
        open_catalog_app(ui, "Tally", COLD_BOOT)
        ui.wait("TALLY", timeout=20)
        ui.wait("Tally: 0", timeout=20)
        ui.key(b"\r")
        ui.wait("Tally: 1", timeout=20)
        ui.wait("Saved: 1", timeout=20)
        ui.quit()
    finally:
        ui.close()

    restarted = Desktop(destination, project=destination)
    try:
        restarted.wait("TALLY", timeout=COLD_BOOT)
        restarted.wait("Tally: 1", timeout=20)
        restarted.quit()
    finally:
        restarted.close()
    # The grants are the destination's own: its owner, its workspace folder
    # and its database, never the source's.
    assert classic_workspace(destination / "workspace.db") == workspace_id
    owner = f"bee.gov.apps:{workspace_id}.tally"
    suffix = hashlib.sha256(f"{owner}\ntally".encode()).hexdigest()
    with sqlite3.connect(f"file:{destination / '.wippy' / 'app-db' / (suffix + '.db')}?mode=ro", uri=True) as db:
        rows = db.execute("SELECT n, note FROM tally_rows ORDER BY rowid").fetchall()
    assert rows == [(1, GREETING)], rows
    print("Workspace application over Hive: the agent-built Tally applied on " + SOURCE_NODE + " crossed Hive, was "
          "admitted on the destination only by its own workspace-applications rule, approved by the destination's "
          "person and opened there with the destination's own file and database grants; evidence in " + str(evidence))


if __name__ == "__main__":
    exercise()

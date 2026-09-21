"""Review an application delivery in the Overlays window before approving it.

Three versions of a private application are staged into the desktop's own
workspace through the production publication and destination chain: one whose
candidate introduces a reference to an entry nothing supplies, one whose
function entry declares an empty modules field the destination's function
config cannot read, and one the destination preflight accepts. Overlays then has to show the destination's
own verdict, the diagnostic that blocks activation, the entry set the plan
changes against the composed base, and the approval and activation record. The
blocked versions must refuse selection with their reason; the ready one is
reviewed, selected and prepared in Overlays, approved in Approvals, and its
activation outcome and receipt read back in the same review surface.
"""
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, database_environment  # noqa: E402

# The cold first boot of a full composition, the budget the sibling desktop
# acceptances (tests/inbox_decide.py, tests/app_journey.py) already use.
COLD_BOOT = 30
DELIVERY = "Overlays"
APPROVALS = "Approvals"
BLOCKED_ENTRY = "bee.delivery_review_blocked:probe"
READY_ENTRY = "bee.delivery_review_ready:probe"
ABSENT_TARGET = "bee.delivery_review_absent:target"
READY_WORKSPACE = "delivery-review-ready"
BLOCKED_WORKSPACE = "delivery-review-blocked"
CONFIG_WORKSPACE = "delivery-review-config"
CONFIG_ENTRY = "bee.delivery_review_config:probe"


def workspace_identity(folder):
    """The delivery app reviews its launch workspace, which the first boot names."""
    connection = sqlite3.connect(folder / "workspace.db")
    try:
        rows = connection.execute("SELECT workspace_id FROM workspace_identity").fetchall()
    finally:
        connection.close()
    assert len(rows) == 1 and re.fullmatch(r"[0-9a-f]{32}", rows[0][0]), rows
    return rows[0][0]


def bind_destination(project, workspace_id):
    index = project / "src/probe/_index.yaml"
    document = yaml.safe_load(index.read_text())
    entry = next(item for item in document["entries"] if item["name"] == "destination")
    entry["data"]["workspace_id"] = workspace_id
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def delay_destination(project, operation, duration="2s"):
    """Delay one destination operation without changing its reply."""
    manifest = project / "src/governance/_index.yaml"
    document = yaml.safe_load(manifest.read_text())
    entry = next(item for item in document["entries"] if item["name"] == "destination_call")
    if "time" not in entry["modules"]:
        entry["modules"].append("time")
    manifest.write_text(yaml.safe_dump(document, sort_keys=False))
    method = project / "src/governance/destination_method.lua"
    source = method.read_text()
    if 'local time = require("time")' not in source:
        source = source.replace('local funcs = require("funcs")',
                                'local funcs = require("funcs")\nlocal time = require("time")')
    source = source.replace(
        '    local result, call_error = executor:call(service.BACKEND, request)',
        f'    if request.operation == "{operation}" then time.sleep("{duration}") end\n'
        '    local result, call_error = executor:call(service.BACKEND, request)',
    )
    method.write_text(source)


def seed(project, folder):
    args = [str(RUNTIME), "run", "--verbose", "delivery-review-seed", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(folder))
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "DELIVERY_REVIEW_SEEDED" in output, output
    match = re.search(r"DELIVERY_REVIEW_SEEDED\s+(\{.*\})", output)
    assert match, output
    evidence = json.loads(match.group(1))
    for name in ("ready_plan_digest", "ready_artifact_digest", "blocked_plan_digest", "config_plan_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), (name, evidence)
    assert evidence["blocked_diagnostics"] >= 1, evidence
    assert evidence["config_diagnostics"] >= 1, evidence
    return evidence


def invoke(project, folder):
    """A separate boot calls the settled entry directly: the review surface's
    outcome names a function that actually runs, not just a descriptor."""
    args = [str(RUNTIME), "run", "--verbose", "delivery-review-invoke", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(folder))
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "DELIVERY_REVIEW_INVOKED" in output, output
    match = re.search(r"DELIVERY_REVIEW_INVOKED\s+(\{.*\})", output)
    assert match, output
    invoked = json.loads(match.group(1))
    assert invoked["result"]["ok"] is True, invoked
    assert invoked["result"]["ready_probe"] == "delivery-review-ready", invoked
    return invoked


def focus(ui, label):
    """Windows are chosen from the taskbar, the way a person switches them."""
    deadline = time.monotonic() + 10
    while True:
        row = ui.screen.display[0]
        if label in row:
            x = row.index(label) + 1
            ui.mouse(0, x, 1)
            ui.mouse(0, x, 1, True)
            ui.pump(.4)
            return
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.3)


def open_review(ui, source_workspace, steps):
    """Move the staged list cursor down and read that version's plan."""
    ui.wait("Staged", timeout=20)
    for _ in range(steps):
        ui.key(b"j")
    ui.key(b"\r")
    ui.wait(source_workspace, timeout=20)
    ui.wait("Verdict", timeout=20)


def back_to_plans(ui):
    ui.key(b"\t")
    ui.wait("Available", timeout=20)
    ui.key(b"\t")
    ui.wait("Staged", timeout=20)


def exercise_responsive():
    """A delayed destination must not hold the Overlays frame or close."""
    with tempfile.TemporaryDirectory(prefix="bee-delivery-responsive-") as directory:
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)

        delay_destination(project, "available")
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True, timeout=300)

        ui = Desktop(folder, project=project, apps=("bee.overlays:app",))
        ui.observed_frames = []
        try:
            deadline = time.monotonic() + COLD_BOOT
            while time.monotonic() < deadline and not any(
                "Working" in "\n".join(frame) for frame in ui.observed_frames
            ):
                ui.pump(.02)
            assert any("OVERLAYS" in "\n".join(frame) for frame in ui.observed_frames), ui.text()
            assert any("Working" in "\n".join(frame) for frame in ui.observed_frames), ui.text()
            ui.resize(72, 24)
            start = time.monotonic()
            ui.key(b"\x1b")
            while "OVERLAYS" in ui.text() and time.monotonic() - start < 1.5:
                ui.pump(.05)
            assert "OVERLAYS" not in ui.text(), ui.text()
            assert time.monotonic() - start < 1.5, "Overlays Escape exceeded 1.5s"
            ui.quit()
        finally:
            ui.close()
    print("Overlays responsiveness: delayed destination still shows progress, resizes and closes within 1.5s")


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-delivery-review-") as directory:
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/delivery_review", project / "src/probe")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)

        # The workspace names itself on its first boot; the staged plans and the
        # host profiles belong to that exact workspace.
        first = Desktop(folder, project=project)
        try:
            first.wait("No applications open", timeout=COLD_BOOT)
            first.quit()
        finally:
            first.close()
        workspace_id = workspace_identity(folder)
        bind_destination(project, workspace_id)
        delay_destination(project, "get")
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True, timeout=300)
        evidence = seed(project, folder)
        assert evidence["workspace_id"] == workspace_id, evidence

        ui = Desktop(folder, project=project, apps=("bee.overlays:app",))
        try:
            ui.wait("OVERLAYS", timeout=COLD_BOOT)
            ui.window_control("□")
            ui.pump(.4)
            ui.key(b"\t")
            ui.wait("Staged", timeout=20)
            ui.wait(BLOCKED_WORKSPACE, timeout=20)
            ui.wait(CONFIG_WORKSPACE, timeout=20)
            ui.wait(READY_WORKSPACE, timeout=20)

            # The refused plan names its verdict, the diagnostic code and the
            # entry that diagnostic concerns, and select is unavailable.
            # A slow read pins the selected plan. Navigation during the call
            # cannot make A's evidence appear beneath B's heading.
            ui.key(b"\r")
            ui.wait("Working", timeout=20)
            ui.key(b"j")
            ui.wait(BLOCKED_WORKSPACE, timeout=20)
            ui.wait("Verdict blocked", timeout=20)
            ui.wait("DANGLING_REFERENCE  " + BLOCKED_ENTRY, timeout=20)
            ui.wait("missing final-state target " + ABSENT_TARGET, timeout=20)
            ui.key(b"s")
            ui.wait("Preflight blocks this version", timeout=20)
            ui.key(b"a")
            ui.wait("Preflight blocks this version", timeout=20)
            assert "settled" not in ui.text(), ui.text()

            # A version whose function entry declares modules as a map is
            # refused for the shape the destination's function config reads.
            back_to_plans(ui)
            open_review(ui, CONFIG_WORKSPACE, 1)
            ui.wait("Verdict blocked", timeout=20)
            ui.wait("CONFIG_SHAPE  " + CONFIG_ENTRY, timeout=20)
            ui.wait("configuration field modules is empty and reaches the destination", timeout=20)
            ui.key(b"s")
            ui.wait("Preflight blocks this version", timeout=20)
            ui.key(b"a")
            ui.wait("Preflight blocks this version", timeout=20)
            assert "Verdict ready" not in ui.text(), ui.text()

            # The accepted plan names its verdict and the entry set it changes
            # against the composed base, and can be reviewed and selected.
            back_to_plans(ui)
            open_review(ui, READY_WORKSPACE, 1)
            ui.wait("Verdict ready", timeout=20)
            ui.wait("No diagnostics and no pending migrations", timeout=20)
            ui.wait("added  " + READY_ENTRY + "  function.lua", timeout=20)
            ui.wait("unbound", timeout=20)
            ui.key(b"a")
            ui.wait("Plan details refreshed", timeout=20)
            ui.key(b"s")
            ui.wait("Plan details refreshed", timeout=20)
            ui.key(b"p")
            ui.wait("Activation approval_bound", timeout=COLD_BOOT)
            ui.wait("proposed  proposal", timeout=20)

            # The decision itself is made by a person in the Approvals window.
            ui.open_start()
            ui.choose("Tools")
            ui.choose(APPROVALS)
            ui.wait("APPROVALS", timeout=COLD_BOOT)
            ui.window_control("□")
            ui.pump(.4)
            ui.wait("bee.governance:establish-overlay", timeout=COLD_BOOT)
            ui.key(b"j")
            ui.key(b"o")
            ui.wait("Asked:", timeout=20)
            ui.key(b"a")
            ui.wait("Approve this request?", timeout=20)
            ui.key(b"\t")
            ui.key(b"\r")
            ui.wait("approved by bee.application:", timeout=COLD_BOOT)

            # Back in the review surface, the activation outcome and the
            # activation owner's receipt are what the ledger records.
            focus(ui, DELIVERY)
            ui.wait(READY_WORKSPACE, timeout=20)
            for _ in range(8):
                ui.key(b"x")
                if "settled  applied" in ui.text():
                    break
                ui.pump(.5)
            ui.wait("settled  applied", timeout=COLD_BOOT)
            ui.wait("consumed  proposal", timeout=20)
            ui.wait("Receipt  overlay bee.delivery_review_probe:ready_overlay", timeout=20)
            ui.wait("Receipt  artifact " + evidence["ready_artifact_digest"][:12], timeout=20)
            ui.quit()
        finally:
            ui.close()

        invoked = invoke(project, folder)
    print("Delivery review: the refused plan shows blocked with DANGLING_REFERENCE on "
          + BLOCKED_ENTRY + ", the empty modules plan shows blocked with CONFIG_SHAPE on "
          + CONFIG_ENTRY + ", both refuse selection, the accepted plan shows ready as a "
          "function.lua entry with its entry changes against the composed base, its approval, "
          "activation outcome and receipt read back in the same review surface, and the applied "
          "entry itself runs on a later boot: " + json.dumps(invoked["result"]))


if __name__ == "__main__":
    exercise_responsive()
    exercise()

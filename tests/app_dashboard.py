"""Deliver the reference dashboard through governance and read it at every size.

The exact sources of the bundled System Monitor are authored as one package
under a namespace of its own, frozen, published, staged, preflighted and
requested for delivery (tests/fixtures/app_dashboard). A person then reviews,
selects, approves and applies it through Overlays and Approvals, opens it from
the desktop catalog and reads live runtime statistics in it at the 80x24,
120x36 and 160x48 size classes of docs/guides/app-style.md.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_journey import COLD_BOOT, apply_staged_in_ui, open_catalog_app, workspace_identity  # noqa: E402
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, database_environment  # noqa: E402

DEFINITION_ID = "bee.monitor_demo:app"
TITLE = "Delivered Monitor"


def admit(project):
    """The host owner admits the definition with the runtime read policy."""
    index = project / "src/security/_index.yaml"
    document = yaml.safe_load(index.read_text())
    admission = next(entry for entry in document["entries"] if entry["name"] == "application_admission")
    admission["bindings"].append({"definition_id": DEFINITION_ID,
                                  "policies": ["bee:ordinary_app_subsystem_boundary", "bee:processes_policy"]})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def deliver(project, folder):
    args = [str(RUNTIME), "run", "--verbose", "app-dashboard-deliver", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True, timeout=300,
                            env=database_environment(folder, BEE_APP_DASHBOARD_WORKSPACE=workspace_identity(folder)))
    output = result.stdout + result.stderr
    match = re.search(r"APP_DASHBOARD_DELIVERED\s+(\{.*\})", output)
    assert result.returncode == 0 and match, output[-12000:]
    evidence = json.loads(match.group(1))
    for name in ("snapshot_digest", "artifact_digest", "plan_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), (name, evidence)
    assert evidence["ready"] is True and evidence["entries"] == 2, evidence
    assert evidence["definition_id"] == DEFINITION_ID and evidence["title"] == TITLE, evidence
    return evidence


def screen_at(ui, width, height, *required):
    """Resize the desktop so the fullscreen application canvas is width x height
    and wait until every required text is visible in one frame. A fullscreen
    window takes every row below the shared bar, so the desktop is one row
    taller than the canvas."""
    ui.resize(width, height + 1)
    deadline = time.monotonic() + 20
    while True:
        ui.pump(.2)
        text = ui.text()
        missing = [needle for needle in required if needle not in text]
        if not missing:
            return text
        assert time.monotonic() < deadline, (width, height, missing, text)


def assert_anatomy(ui, height, text):
    """Header on the first application row, tiles below it, the action bar on
    the penultimate row and the key hints on the last."""
    rows = ui.screen.display[1:]
    assert len(rows) == height, text
    assert rows[0].startswith(" SYSTEM MONITOR") and "Live · 1s" in rows[0], text
    assert rows[2].startswith(" HEAP") and "SCHEDULER" in rows[2], text
    assert rows[height - 2].startswith("  Enter Refresh   P Pause"), text
    assert rows[height - 1].startswith(" Enter refresh · P pause · Esc close"), text


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-app-dashboard-") as directory, \
            patch.dict(os.environ, {"WIPPY_NODE_ID": Path(directory).name}):
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        shutil.copytree(ROOT / "tests/fixtures/app_dashboard", project / "src/dashboard_probe")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        admit(project)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                        "--set", "lua.type_system.strict=true"], cwd=project, check=True, timeout=300)
        initial = Desktop(folder, project=project)
        try:
            initial.wait("No applications open", timeout=COLD_BOOT)
            initial.quit()
        finally:
            initial.close()

        evidence = deliver(project, folder)
        ui = Desktop(folder, project=project)
        try:
            ui.wait("No applications open", timeout=COLD_BOOT)
            apply_staged_in_ui(ui, evidence, folder)
            open_catalog_app(ui, TITLE, COLD_BOOT)
            ui.wait("SYSTEM MONITOR", timeout=20)
            ui.key(b"\x1b[23~")
            ui.wait("▣ " + TITLE, timeout=20)

            compact = screen_at(ui, 80, 24, "SYSTEM MONITOR", "Live · 1s", "HEAP", "SCHEDULER", "PROCESSES BY STATE",
                                "SERVICES", "running", "MiB ┤", "-60s", "Enter Refresh", "P Pause",
                                "Enter refresh · P pause · Esc close")
            assert_anatomy(ui, 24, compact)
            assert "HOSTS" not in compact and "TOPOLOGY" not in compact, compact
            assert re.search(r"\d[\d.,]*k? steps/s", compact), compact

            standard = screen_at(ui, 120, 36, "HOSTS", "bee:workers", "MEMORY", "reserved", "objects · ")
            assert_anatomy(ui, 36, standard)
            assert "TOPOLOGY" not in standard, standard
            assert re.search(r"Heap █*░* \d+%", standard), standard

            wide = screen_at(ui, 160, 48, "TOPOLOGY", "● node", "▸● bee:", "STEPS PER PROCESS")
            assert_anatomy(ui, 48, wide)
            assert re.search(r"\d+ processes", wide), wide

            ui.key(b"p")
            ui.wait("Paused", timeout=20)
            ui.wait("P Resume", timeout=20)
            ui.key(b"p")
            ui.wait("Live · 1s", timeout=20)
            ui.key(b"\x1b")
            ui.wait("No applications open", timeout=20)
            ui.quit()
        finally:
            ui.close()
    print("App dashboard: the System Monitor sources authored as " + DEFINITION_ID + ", staged as plan "
          + evidence["plan_digest"][:12] + " with a ready preflight, approved, applied, opened from the "
          "catalog and read live at 80x24, 120x36 and 160x48")


if __name__ == "__main__":
    exercise()

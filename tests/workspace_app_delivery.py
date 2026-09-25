"""An agent builds an application to a written spec on an unmodified install.

The composition is the shipped one: its Governance publication and activation
profiles and its approver policies are compared byte for byte with the source
tree, and nothing configures a profile. A managed agent, launched through the
production launch definition, admission, carrier, placement and gateway with
the spec (tests/fixtures/workspace_app_delivery/SPEC.md) as its brief, authors
the application using only its gateway tools: the overlay guide, its own
overlay, freeze and a delivery request that names no workspace. The person then
reviews the plan in Overlays and approves it in Approvals, the activation owner
applies it, and the application opens from the Start menu and behaves as the
spec says, including its saved count after a restart.

The far end of the launch is the scripted protocol agent
(tests/fixtures/harness/gateway_client.go, mode spec): it writes the answer a
model would write, tests/fixtures/workspace_app_delivery/tally.lua, so the
proof needs no provider account. BEE_WORKSPACE_APP_PROVIDER=claude runs the
installed Claude Code at that end instead; it reads the spec and the guide and
writes the application itself, consuming inference. BEE_RUNTIME names the
runtime; BEE_WORKSPACE_APP_EVIDENCE overrides the retained evidence directory.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_journey import apply_staged_in_ui, open_catalog_app  # noqa: E402
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, classic_workspace, database_environment  # noqa: E402

FIXTURE = ROOT / "tests/fixtures/workspace_app_delivery"
COLD_BOOT = 30
SOURCE = "tally"
VERSION = "1.0.0"
TITLE = "Tally"
DEFINITION_ID = "app.tally:app"
APPROVAL_POLICY = "workspace-application-delivery"
SHIPPED = ["modules/gov/src/_index.yaml", "src/_index.yaml"]
PROVIDER = os.environ.get("BEE_WORKSPACE_APP_PROVIDER", "scripted")
# A live agent is told only how to use its tools; the spec is the person's.
LIVE_BRIEF = ("Use only the Bee MCP tools; never a shell, a file tool or another agent. Read the overlay tool's "
              "guide operation first and follow it. Author the application below in your own overlay, freeze it, "
              "then call the delivery tool with operation request, version 1.0.0 and the frozen snapshot_digest. "
              "If delivery names a diagnostic, repair it, freeze again and request delivery with version 1.0.1, "
              "1.0.2 and so on. Stop when delivery reports ready.\n\n")


def answer_entries():
    """The entries.json a model writes for SPEC.md."""
    return [{"id": DEFINITION_ID, "kind": "process.lua",
             "data": {"source": (FIXTURE / "tally.lua").read_text(), "method": "main",
                      "modules": ["tty", "process", "channel", "json"],
                      "imports": {"client": "bee.application:client", "appearance": "bee.application:appearance",
                                  "frame": "bee.application:frame"}},
             "meta": {"type": "bee.application", "application": {
                 "api_version": 1, "lifetime": "view", "revision": "1", "title": TITLE,
                 "instance_policy": "singleton", "resume_schema": "tally.v1", "restart_policy": "automatic"}}}]


def compose(folder):
    project = folder / "project"
    shutil.copytree(ROOT / "src", project / "src")
    shutil.copytree(ROOT / "modules", project / "modules")
    for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
        shutil.copy2(ROOT / name, project / name)
    shutil.copytree(FIXTURE, project / "src/workspace_app_probe")
    for relative in SHIPPED:
        assert (project / relative).read_bytes() == (ROOT / relative).read_bytes(), relative
    answer = folder / "entries.json"
    answer.write_text(json.dumps(answer_entries()))
    index = project / "src/workspace_app_probe/_index.yaml"
    document = yaml.safe_load(index.read_text())
    policy = next(entry for entry in document["entries"] if entry["name"] == "agent_policy")["data"]
    if PROVIDER == "claude":
        executable = shutil.which("claude")
        assert executable, "BEE_WORKSPACE_APP_PROVIDER=claude needs an installed, logged-in Claude Code"
        policy["executables"] = {"claude": str(Path(executable).resolve())}
        policy["environment"] = {}
        policy["environment_refs"] = {"CLAUDE_CONFIG_DIR": "bee.driver.claude:config_home"}
        policy["allow_host_home"] = True
        policy["prepare_options"] = {"permission_mode": "dontAsk", "max_turns": 32}
        policy["required_exit_observation"] = "independent"
        policy["required_cleanup"] = "process_group"
        policy["stop_grace_ms"] = 5000
        policy["drain_ms"] = 5000
        policy.pop("runner_drain_ms", None)
        policy["fixture"] = False
    else:
        assert PROVIDER == "scripted", PROVIDER
        policy["executables"] = {"claude": str(ROOT / "tests/fixtures/harness/bin/claude")}
        policy["environment"]["BEE_FIXTURE_AUTHOR_ENTRIES"] = str(answer)
        policy["environment"]["BEE_FIXTURE_STREAM"] = str(ROOT / "tests/fixtures/drivers/claude/stream-json-2/plain.jsonl")
    index.write_text(yaml.safe_dump(document, sort_keys=False))
    subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                    "--set", "lua.type_system.strict=true"], cwd=project, check=True, timeout=300)
    return project


def author(project, folder):
    """The managed agent's attempt, started by the host with the spec as brief."""
    workspace_id = classic_workspace(folder / "workspace.db")
    spec = (FIXTURE / "SPEC.md").read_text()
    brief = LIVE_BRIEF + spec if PROVIDER == "claude" else spec
    result = subprocess.run([str(RUNTIME), "run", "--verbose", "workspace-app-author",
                             "--set", f"registry.history_path={folder}/registry.db"],
                            cwd=project, capture_output=True, text=True, timeout=1500,
                            env=database_environment(folder, BEE_WORKSPACE_APP_WORKSPACE=workspace_id,
                                                     BEE_WORKSPACE_APP_BRIEF=brief))
    output = result.stdout + result.stderr
    (folder / "author.log").write_text(output)
    assert result.returncode == 0, output[-6000:]
    match = re.search(r"WORKSPACE_APP_AUTHORED\s+(\{.*\})", output)
    assert match, output[-6000:]
    return json.loads(match.group(1))


def assert_authored(report):
    # The installed agent's own tools, the shipped Claude surface.
    for tool in ("overlay", "delivery", "docs", "components"):
        assert tool in report["author_tools"], report
    assert report["guide_names_rule"] is True, report
    assert report["create_ok"] is True and report["put_ok"] is True, report
    assert re.fullmatch(r"[0-9a-f]{64}", report["snapshot_digest"] or ""), report
    # The shipped host profiles admit the overlay: a ready verdict, no finding.
    assert report["delivery_ok"] is True, report
    assert report["delivery_ready"] is True and report["delivery_diagnostics"] == [], report
    assert report["delivery_component"] == "app.tally", report
    assert report["delivery_human_steps"] == 6, report
    # Status reads the same staged plan back with no source node named.
    assert report["status_ok"] is True, report
    assert report["status_plan_digest"] == report["delivery_plan_digest"], report
    assert report["status_selected"] is not True, report


def staged_version(folder):
    """The version the agent's last delivery request staged for its overlay."""
    with sqlite3.connect(f"file:{folder / 'governance.db'}?mode=ro", uri=True) as db:
        rows = db.execute("SELECT version FROM bee_governance_plans WHERE source_workspace = ? ORDER BY rowid",
                          (SOURCE,)).fetchall()
    assert rows, "the agent staged no version of " + SOURCE
    return rows[-1][0]


def evidence_root():
    selected = os.environ.get("BEE_WORKSPACE_APP_EVIDENCE")
    root = Path(selected) if selected else ROOT / ".wippy/evidence" / time.strftime("workspace-app-%Y%m%d-%H%M%S")
    root.mkdir(parents=True, exist_ok=False)
    return root


def exercise():
    folder = evidence_root()
    print("Evidence:", folder)
    project = compose(folder)
    first = Desktop(folder, project=project)
    try:
        first.wait("No applications open", timeout=COLD_BOOT)
        first.quit()
    finally:
        first.close()

    report = author(project, folder)
    if PROVIDER == "scripted":
        assert_authored(report)

    ui = Desktop(folder, project=project)
    try:
        ui.wait("No applications open", timeout=COLD_BOOT)
        ui.pump(.5)
        version = staged_version(folder)
        assert PROVIDER != "scripted" or version == VERSION, version
        apply_staged_in_ui(ui, {"workspace": SOURCE, "version": version, "approval_policy": APPROVAL_POLICY}, folder)
        open_catalog_app(ui, TITLE, COLD_BOOT)
        ui.wait("TALLY", timeout=20)
        ui.wait("Tally: 0", timeout=20)
        ui.key(b"\r")
        ui.wait("Tally: 1", timeout=20)
        ui.wait("Saved: 1", timeout=20)
        ui.key(b"\r")
        ui.wait("Tally: 2", timeout=20)
        ui.key(b"r")
        ui.wait("Tally: 0", timeout=20)
        ui.wait("Saved: 0", timeout=20)
        for count in (1, 2, 3):
            ui.key(b"\r")
            ui.wait(f"Tally: {count}", timeout=20)
        ui.wait("Saved: 3", timeout=20)
        ui.quit()
    finally:
        ui.close()

    restarted = Desktop(folder, project=project)
    try:
        restarted.wait("TALLY", timeout=COLD_BOOT)
        restarted.wait("Tally: 3", timeout=20)
        restarted.quit()
    finally:
        restarted.close()
    print("Workspace application: a managed agent authored " + DEFINITION_ID + " from its written spec on the "
          "shipped host profiles, the person approved it in Approvals, and it opened from Start, counted, reset "
          "and restored its saved count")


if __name__ == "__main__":
    exercise()

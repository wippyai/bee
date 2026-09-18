"""A managed coding agent authors a Bee application; a person approves it; it opens.

A real managed Agy attempt is launched through the production launch definition,
admission, carrier, placement and gateway with a brief and host instructions. It
authors one application into its own Governance workspace through the scoped MCP
workspace tool and freezes it. The host lints the frozen source, publishes it,
stages it into the desktop's own workspace and reads the destination's preflight
verdict; a refusal returns to the agent as a record on its bound thread and it
repairs, bounded to a small number of rounds. The person then reviews the plan in
App Delivery, approves it in Approvals, and the activation owner applies it. The
application appears in the start menu, opens as a window with the content the
agent authored, and comes back with its state after a full host restart.

Requires the installed Agy login and consumes inference. BEE_RUNTIME names the
runtime; BEE_AGENT_APP_EVIDENCE overrides the retained evidence directory.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_journey import assert_overlay_authority  # noqa: E402
from delivery_review import back_to_plans, focus, workspace_identity  # noqa: E402
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, database_environment  # noqa: E402

ROUNDS = 3
# The cold first boot of a full composition, the budget the sibling desktop
# acceptances (tests/app_journey.py, tests/delivery_review.py) already use.
COLD_BOOT = 30
DEFINITION_ID = "bee.agent_app_demo:app"
TITLE = "Agent App"
MARKER = "AGENT APP READY"
DELIVERY = "App Delivery"
APPROVALS = "Approvals"
OVERLAY_OWNER = "bee.agent_app_probe:activation_overlay"
ADMITTED_TOOLS = ["app_docs", "thread_message", "thread_read", "workspace"]
ACTIVE_TRAITS = ["app:author", "app:read"]
MATERIAL = {"contract": "tests/fixtures/agent_app/CONTRACT.md", "client": "src/ui/application/client.lua",
            "example": "src/apps/timeline/app.lua", "view": "src/apps/timeline/view.lua"}


def evidence_root():
    selected = os.environ.get("BEE_AGENT_APP_EVIDENCE")
    root = Path(selected) if selected else ROOT / ".wippy/evidence" / time.strftime("agent-app-%Y%m%d-%H%M%S")
    root.mkdir(parents=True, exist_ok=True)
    return root


def provider():
    """The live provider is required: no fixture stands in for this proof."""
    path = shutil.which(os.environ.get("BEE_AGY_BIN", "agy"))
    if not path:
        sys.exit("Install Agy and log it in: this acceptance proves a real managed agent authors the application")
    return str(Path(path).resolve())


def set_variable(project, relative, name, variable):
    """Name the host bindings this fixture supplies, the way tests/live_agy_mcp.go
    does: the native launcher normally supplies them under its own names."""
    index = project / relative
    document = yaml.safe_load(index.read_text())
    entry = next(item for item in document["entries"] if item["name"] == name)
    assert entry["kind"] == "env.variable", entry
    entry["variable"] = variable
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def bind_host():
    """Every boot of this composition reads the same host bindings, the way the
    native launcher supplies them to an installed Bee."""
    os.environ["BEE_AGENT_APP_AGY"] = provider()
    os.environ["BEE_AGENT_APP_HOME"] = os.path.expanduser("~")


def rewrite(index, name, data):
    document = yaml.safe_load(index.read_text())
    entry = next(item for item in document["entries"] if item["name"] == name)
    entry["data"] = data
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def stage_material(project):
    """The documents the host hands the agent through its one admitted read tool."""
    rewrite(project / "src/probe/_index.yaml", "material",
            {topic: (ROOT / path).read_text() for topic, path in MATERIAL.items()})


def write_inputs(project, **values):
    rewrite(project / "src/probe/_index.yaml", "inputs",
            {"round": "", "source_workspace": "", "launch_workspace": "", "destination_workspace": "",
             "version": "", "snapshot_digest": "", "artifact_digest": "", "findings": "", **values})


def admit_docs_tool(project):
    """Tool metadata grants nothing: the host admits this exact operation."""
    index = project / "src/gateway/_index.yaml"
    document = yaml.safe_load(index.read_text())
    endpoint = next(entry for entry in document["entries"] if entry["name"] == "mcp_http")
    endpoint["security"]["policies"].append("bee.agent_app_probe:docs_policy")
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def bind_admission(project):
    """The host owner admits the definition; registry metadata cannot."""
    index = project / "src/security/_index.yaml"
    document = yaml.safe_load(index.read_text())
    admission = next(entry for entry in document["entries"] if entry["name"] == "application_admission")
    admission["bindings"].append({"definition_id": DEFINITION_ID,
                                  "policies": ["bee:ordinary_app_subsystem_boundary"]})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def diagnostics(output):
    """The typed errors themselves, without the progress noise around them."""
    blocks, current = [], []
    for line in output.replace("\r", "\n").splitlines():
        if line.startswith("Linting...") or line.startswith("Checked "):
            continue
        if line.strip():
            current.append(line.rstrip())
        elif current:
            blocks.append(current)
            current = []
    if current:
        blocks.append(current)
    reported = ["\n".join(block) for block in blocks if block[0].startswith("error[")]
    return "\n\n".join(reported)[:8000]


def lint(folder, label):
    result = subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                             "--set", "lua.type_system.strict=true"], cwd=folder,
                            capture_output=True, text=True, timeout=300)
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + result.stderr)
    assert result.returncode == 0 or label != "host", output
    if result.returncode == 0:
        return None
    reported = diagnostics(output)
    assert reported, output
    return "the host typed lint refuses the source you authored:\n" + reported


def command(project, folder, name, label, timeout, host=None):
    environment = database_environment(folder)
    args = [str(RUNTIME), "run", "--verbose", name]
    if host:
        args += ["--host", host]
    result = subprocess.run(args + ["--set", f"registry.history_path={folder}/registry.db"],
                            cwd=project, capture_output=True, text=True, timeout=timeout, env=environment)
    output = result.stdout + result.stderr
    (folder / (label + ".log")).write_text(output)
    assert result.returncode == 0, f"{label} failed; evidence in {folder}\n" + output[-4000:]
    return output


def author(project, folder, round_label):
    """One managed attempt, through the real launch definition and gateway."""
    output = command(project, folder, "agent-app-author", "author-" + round_label, 900)
    match = re.search(r"AGENT_APP_AUTHORED\s+(\{.*\})", output)
    assert match, output[-4000:]
    report = json.loads(match.group(1))
    # The attempt's own binding admits four scoped tools. None of them reaches
    # publication, approval or the registry overlay.
    assert report["admitted_tools"] == ADMITTED_TOOLS, report["admitted_tools"]
    if report["findings"]:
        return report
    assert re.fullmatch(r"[0-9a-f]{64}", report["snapshot_digest"]), report["snapshot_digest"]
    assert report["requested_access"] is True, report
    assert report["active_traits"] == ACTIVE_TRAITS, report["active_traits"]
    assert report["context"] == {"round": round_label}, report["context"]
    return report


def contract_findings(report):
    """What a reviewer answers for before the destination ever sees the plan."""
    if report["findings"]:
        return report["findings"]
    entries = report["entries"]
    if len(entries) != 1:
        return ("entries.json must hold exactly one entry, the application definition; it holds "
                + str(len(entries)) + ": " + ", ".join(str(entry.get("id")) for entry in entries))
    entry = entries[0]
    if entry.get("id") != DEFINITION_ID or entry.get("kind") != "process.lua":
        return ("the application entry must be " + DEFINITION_ID + " of kind process.lua; it is "
                + str(entry.get("id")) + " of kind " + str(entry.get("kind")))
    application = (entry.get("meta") or {}).get("application") or {}
    if (entry.get("meta") or {}).get("type") != "bee.application":
        return "the application entry declares no meta.type bee.application"
    if application.get("title") != TITLE:
        return "the application metadata must declare the title " + TITLE + "; it declares " + str(application.get("title"))
    if not application.get("resume_schema"):
        return "the application metadata declares no resume_schema, so the window cannot checkpoint its state"
    return None


def candidate_findings(folder, project, entries, round_label):
    """Typed lint of the authored source, in a separate review tree that is
    neither added to a running host nor applied to its registry."""
    review = folder / ("review-" + round_label)
    shutil.copytree(project, review)
    candidate = {"version": "1.0", "namespace": DEFINITION_ID.split(":")[0], "entries": []}
    for entry in entries:
        copied = dict(entry)
        identity = copied.pop("id")
        copied["name"] = identity.split(":", 1)[1]
        candidate["entries"].append(copied)
    (review / "src/agent_candidate").mkdir(parents=True)
    (review / "src/agent_candidate/_index.yaml").write_text(yaml.safe_dump(candidate, sort_keys=False))
    return lint(review, "candidate")


def stage(project, folder, round_label):
    output = command(project, folder, "agent-app-stage", "stage-" + round_label, 300, host="bee:workers")
    match = re.search(r"AGENT_APP_STAGED\s+(\{.*\})", output)
    assert match, output[-4000:]
    return json.loads(match.group(1))


def preflight_diagnostic(diagnostic):
    """One destination diagnostic as the agent reads it. The preflight wire
    contract names the field remedy (src/governance/preflight.lua), so a
    reviewer that read another name would drop the destination's own repair
    instruction and hand back a weaker finding than the host observed."""
    return (str(diagnostic.get("code")) + " on " + str(diagnostic.get("target")) + ": "
            + str(diagnostic.get("message")) + " " + str(diagnostic.get("remedy")))


def preflight_findings(staged):
    if staged["ready"] and not staged["pending_migrations"]:
        return None
    lines = ["the destination refused this version at preflight:"]
    reported = staged["diagnostics"]
    for diagnostic in (reported.values() if isinstance(reported, dict) else reported):
        lines.append(preflight_diagnostic(diagnostic))
    if staged["pending_migrations"]:
        lines.append("the version carries pending migrations, which this destination does not run")
    return "\n".join(lines)


def review_contract_check():
    """No inference and no host: the reviewer must carry exactly the field the
    destination emits, before the live chain ever runs."""
    dispatched = preflight_findings({"ready": False, "pending_migrations": 0, "diagnostics": [
        {"code": "CONFIG_SHAPE", "target": DEFINITION_ID, "message": "modules must not be empty",
         "remedy": "omit an empty modules list"}]})
    assert "omit an empty modules list" in dispatched, dispatched
    assert "None" not in dispatched, dispatched
    assert preflight_findings({"ready": True, "pending_migrations": 0, "diagnostics": []}) is None


def open_plan(ui, label):
    """Read one staged version's plan in the review pane, by the workspace it came from."""
    for index in range(8):
        ui.wait("STAGED PLANS", timeout=20)
        for _ in range(index):
            ui.key(b"j")
        ui.key(b"\r")
        # Reading a plan asks the destination for it and for its entry changes.
        deadline, opened = time.monotonic() + 20, None
        while opened is None and time.monotonic() < deadline:
            opened = re.search(r"REVIEW (\S+)  version", ui.text())
            if opened is None:
                ui.pump(.3)
        assert opened, "the chosen staged version did not open its plan\n" + ui.text()
        if opened.group(1) == label:
            return
        back_to_plans(ui)
    raise AssertionError("no staged plan from " + label + "\n" + ui.text())


def open_admitted(ui, timeout):
    """The application is chosen from the desktop's own catalog, never from a
    command line. The broker refreshes admission from the effective catalog by
    itself, so poll the catalog rather than the clock."""
    deadline = time.monotonic() + timeout
    while True:
        ui.open_start()
        if TITLE in ui.text():
            ui.choose(TITLE)
            return
        ui.key(b"\x1b")
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.5)


def review_and_apply(folder, project, staged):
    """What the person does: read the verdict and the entry changes, accept,
    select and prepare here, approve in Approvals, and step."""
    ui = Desktop(folder, project=project, apps=("bee.delivery:app",))
    try:
        ui.wait("APP DELIVERY", timeout=COLD_BOOT)
        ui.window_control("□")
        ui.pump(.4)
        ui.key(b"\t")
        ui.wait("STAGED PLANS", timeout=20)
        open_plan(ui, staged["source_workspace"])
        ui.wait("Verdict ready", timeout=20)
        ui.wait("No diagnostics and no pending migrations", timeout=20)
        ui.wait("added  " + DEFINITION_ID + "  process.lua", timeout=20)
        ui.key(b"a")
        ui.wait("Plan details refreshed", timeout=20)
        ui.key(b"s")
        ui.wait("Plan details refreshed", timeout=20)
        ui.key(b"p")
        ui.wait("Activation approval_bound", timeout=COLD_BOOT)
        ui.wait("proposed  proposal", timeout=20)

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
        ui.wait("approved by bee.local", timeout=COLD_BOOT)

        focus(ui, DELIVERY)
        ui.wait("REVIEW " + staged["source_workspace"], timeout=20)
        for _ in range(8):
            ui.key(b"x")
            if "settled  applied" in ui.text():
                break
            ui.pump(.5)
        ui.wait("settled  applied", timeout=COLD_BOOT)
        ui.wait("consumed  proposal", timeout=20)
        # The overlay is the activation owner's own receipt.
        ui.wait("Receipt  overlay " + OVERLAY_OWNER, timeout=20)
        ui.wait("Receipt  artifact " + staged["artifact_digest"][:12], timeout=20)

        # The applied definition is opened from the desktop's own catalog.
        open_admitted(ui, COLD_BOOT)
        ui.wait(MARKER, timeout=COLD_BOOT)
        ui.wait("Count: 0")
        ui.key(b"x")
        ui.wait("Count: 1")
        # The counter the window shows is the one the broker committed.
        ui.wait("Saved: 1", timeout=20)
        ui.quit()
    finally:
        ui.close()


def restore(folder, project):
    restarted = Desktop(folder, project=project)
    try:
        restarted.wait(TITLE, timeout=COLD_BOOT)
        focus(restarted, TITLE)
        restarted.wait(MARKER, timeout=COLD_BOOT)
        restarted.wait("Count: 1", timeout=20)
        restarted.open_start()
        assert TITLE in restarted.text(), restarted.text()
        restarted.key(b"\x1b")
        restarted.pump(.5)
        restarted.quit()
    finally:
        restarted.close()


def exercise():
    review_contract_check()
    bind_host()
    folder = evidence_root()
    print("Private evidence:", folder)
    project = folder / "project"
    shutil.copytree(ROOT / "src", project / "src")
    shutil.copytree(ROOT / "tests/fixtures/agent_app", project / "src/probe")
    for name in [".wippy.yaml", "wippy.lock"]:
        shutil.copy2(ROOT / name, project / name)
    stage_material(project)
    set_variable(project, "src/driver/agy/_index.yaml", "executable", "BEE_AGENT_APP_AGY")
    set_variable(project, "src/environment/_index.yaml", "machine_home", "BEE_AGENT_APP_HOME")
    admit_docs_tool(project)
    bind_admission(project)
    assert_overlay_authority(project)
    write_inputs(project)
    lint(project, "host")

    # The workspace names itself on its first boot; the staged plans, the launch
    # and the host profiles all belong to that exact workspace.
    first = Desktop(folder, project=project)
    try:
        first.wait("No applications open", timeout=COLD_BOOT)
        first.quit()
    finally:
        first.close()
    workspace_id = workspace_identity(folder)

    findings, report, staged = "", None, None
    for round_number in range(1, ROUNDS + 1):
        label = str(round_number)
        source_workspace = "agent-app-source-" + label
        write_inputs(project, round=label, source_workspace=source_workspace,
                     launch_workspace=workspace_id, findings=findings)
        report = author(project, folder, label)
        findings = contract_findings(report) or candidate_findings(folder, project, report["entries"], label) or ""
        if findings:
            print("Round " + label + " returns to the agent: " + findings.splitlines()[0])
            continue
        write_inputs(project, round=label, source_workspace=source_workspace,
                     launch_workspace=workspace_id, destination_workspace=workspace_id,
                     version="1.0." + label, snapshot_digest=report["snapshot_digest"],
                     artifact_digest=report["artifact_digest"])
        staged = stage(project, folder, label)
        findings = preflight_findings(staged) or ""
        if not findings:
            break
        print("Round " + label + " returns to the agent: " + findings.splitlines()[0])
        staged = None
    assert staged is not None, "the agent did not reach a ready version in " + str(ROUNDS) + " rounds: " + findings

    assert [item["id"] for item in staged["added"]] == [DEFINITION_ID], staged["added"]
    assert staged["overlay_owner"] == OVERLAY_OWNER, staged
    review_and_apply(folder, project, staged)
    restore(folder, project)
    (folder / "authored.json").write_text(json.dumps({"snapshot_digest": report["snapshot_digest"],
                                                      "artifact_digest": report["artifact_digest"],
                                                      "plan_digest": staged["plan_digest"],
                                                      "source_workspace": staged["source_workspace"],
                                                      "entries": report["entries"]}, indent=2))
    print("Agent-authored application: a live managed Agy attempt authored " + DEFINITION_ID
          + " through the scoped Governance MCP workspace tool and froze it as "
          + report["snapshot_digest"][:12] + " (artifact " + report["artifact_digest"][:12]
          + "), typed lint passed, the destination staged it as plan " + staged["plan_digest"][:12]
          + " with a ready preflight, a person reviewed, selected, prepared and approved it, "
          + OVERLAY_OWNER + " applied the overlay, and the application opened from the desktop "
            "catalog and was restored with its state after a host restart; evidence in " + str(folder))


if __name__ == "__main__":
    exercise()

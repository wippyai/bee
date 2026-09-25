"""A managed coding agent authors a Bee application; a person approves it; it opens.

A real managed Agy attempt is launched through the production launch definition,
admission, carrier, placement and gateway with a brief and host instructions. It
authors one application into its own Governance overlay through the scoped MCP
overlay tool and freezes it. The host lints the frozen source, publishes it,
stages it into the desktop's own workspace and reads the destination's preflight
verdict; a refusal returns to the agent as a record on its bound thread and it
repairs, bounded to a small number of rounds. The person then reviews the plan in
Overlays, approves it in Approvals, and the activation owner applies it. The
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
from delivery_review import back_to_plans, focus  # noqa: E402
from tui_smoke import DESKTOP_HANG_SECONDS, Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, classic_workspace, database_environment, workspace_checkpoint  # noqa: E402

ROUNDS = 3
UPDATE_ROUNDS = 4
# The cold first boot of a full composition, the budget the sibling desktop
# acceptances (tests/app_journey.py, tests/delivery_review.py) already use.
COLD_BOOT = 30
DEFINITION_ID = "bee.agent_app_demo:app"
TITLE = "Agent App"
MARKER = "AGENT APP READY"
UPDATE_MARKER = "AGENT APP UPDATED"
DELIVERY = "Overlays"
APPROVALS = "Approvals"
OVERLAY_OWNER = "bee.agent.app.probe:activation_overlay"
SOURCE_WORKSPACE = "agent-app-source"
AUTHORING_THREAD = "agent-app-authoring"
ADMITTED_TOOLS = ["app_docs", "overlay", "thread_message", "thread_read"]
ACTIVE_TRAITS = ["app:author", "app:read"]
MATERIAL = {"contract": "tests/fixtures/agent_app/CONTRACT.md", "client": "modules/application/src/client.lua",
            "example": "src/threads/timeline/app.lua", "view": "src/threads/timeline/view.lua"}


def evidence_root():
    selected = os.environ.get("BEE_AGENT_APP_EVIDENCE")
    root = Path(selected) if selected else ROOT / ".wippy/evidence" / time.strftime("agent-app-%Y%m%d-%H%M%S")
    root.mkdir(parents=True, exist_ok=True)
    return root


def configure_source_node(project):
    """Give the continuous Hive acceptance a stable identity before any
    Governance row is created. Ordinary authoring keeps the runtime-selected
    local identity."""
    selected = os.environ.get("BEE_AGENT_APP_NODE_NAME")
    if not selected:
        return
    assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", selected), selected
    path = project / ".wippy.yaml"
    document = yaml.safe_load(path.read_text())
    document["relay"] = {"node_name": selected}
    path.write_text(yaml.safe_dump(document, sort_keys=False))


def configure_continuous_source(project, workspace_id):
    if os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_FIXTURE") != "1":
        return
    governance_path = project / "src/env/_index.yaml"
    governance = yaml.safe_load(governance_path.read_text())
    publication = next(item for item in governance["entries"] if item["name"] == "gov_publication_profiles")
    publication["data"] = {"profiles": [{"workspace_id": workspace_id,
        "source_workspace": SOURCE_WORKSPACE, "component": "bee.agent_app_demo/app",
        "overlay_owner": OVERLAY_OWNER}]}
    activation = next(item for item in governance["entries"] if item["name"] == "gov_activation_profiles")
    activation["data"] = {"profiles": [{"workspace_id": workspace_id, "source_node": "node-1",
        "source_workspace": SOURCE_WORKSPACE, "component": "bee.agent_app_demo/app", "resolver": "overlay",
        "overlay_owner": OVERLAY_OWNER, "approval_policy": "local-agent-app-delivery", "parameters": [],
        "applications": [{"definition_id": DEFINITION_ID,
                          "policies": ["bee.security:ordinary_app_subsystem_boundary"],
                          "thread_access": "observe_post"}],
        "allow": {"packages": ["bee.agent_app_demo/app"], "namespaces": ["bee.agent_app_demo"],
                  "kinds": ["process.lua"], "databases": [], "grants": [],
                  "modules": ["tty", "process", "channel", "json"]}}]}
    governance_path.write_text(yaml.safe_dump(governance, sort_keys=False))
    approvals_path = project / "src/_index.yaml"
    approvals = yaml.safe_load(approvals_path.read_text())
    policies = next(item for item in approvals["entries"] if item["name"] == "approver_policies")
    policies["policies"] = [{"name": "local-agent-app-delivery",
                             "approvers": [{"definition_id": "bee.approvals.inbox:app"}],
                             "max_ttl_ms": 600000}]
    approvals_path.write_text(yaml.safe_dump(approvals, sort_keys=False))


def ui_evidence(folder):
    evidence = {"schema": 1, "provider_seconds": {}, "local_ui_seconds": {}, "frames": []}
    (folder / "ui").mkdir(exist_ok=True)
    (folder / "ui-evidence.json").write_text(json.dumps(evidence, indent=2))
    return evidence


def save_evidence(folder, evidence):
    (folder / "ui-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True))


def record_seconds(folder, evidence, group, name, started):
    elapsed = time.monotonic() - started
    evidence[group][name] = round(elapsed, 3)
    save_evidence(folder, evidence)
    return elapsed


def frame_boundary(ui):
    """Mark the end of the complete frames observed before an action."""
    frames = getattr(ui, "observed_frames", None)
    assert frames is not None, "UI evidence requires observed synchronized frames"
    return len(frames)


def find_frame(ui, boundary, required):
    frames = getattr(ui, "observed_frames", [])
    for index in range(len(frames) - 1, boundary - 1, -1):
        frame = frames[index]
        contents = "\n".join(frame)
        if all((item.search(contents) is not None) if hasattr(item, "search") else (item in contents)
               for item in required):
            return index, frame
    return None, None


def wait_frame(ui, boundary, *required, timeout=20):
    """Wait only for a complete synchronized frame observed after boundary."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        index, frame = find_frame(ui, boundary, required)
        if frame is not None:
            return index, frame
        ui.pump(.05)
    wanted = [item.pattern if hasattr(item, "pattern") else item for item in required]
    raise AssertionError("no complete synchronized frame after boundary for "
                         + ", ".join(wanted) + "\n" + ui.text())


def capture_frame(folder, evidence, ui, name, boundary, *required):
    """Retain a complete DEC-synchronized frame observed after boundary."""
    index, frame = find_frame(ui, boundary, required)
    assert frame is not None, "no complete synchronized frame after boundary for " + name + "\n" + ui.text()
    selected = "\n".join(frame)
    relative = "ui/" + name + ".txt"
    (folder / relative).write_text(selected + "\n")
    evidence["frames"].append({"name": name, "path": relative, "required": list(required),
                                 "boundary": boundary, "observed_frame": index})
    save_evidence(folder, evidence)
    return frame


def saved_app_identity(folder):
    applications = workspace_checkpoint(folder / "workspace.db")["applications"]
    matches = [item for item in applications if item["definition_id"] == DEFINITION_ID]
    assert len(matches) == 1, matches
    return matches[0]["id"], matches[0]["instance_id"]


def provider():
    """The live provider is required: no fixture stands in for this proof."""
    path = shutil.which(os.environ.get("BEE_AGY_BIN", "agy"))
    if not path:
        sys.exit("Install Agy and log it in: this acceptance proves a real managed agent authors the application")
    return str(Path(path).resolve())


def stamp_presenter(project):
    """Give this disposable composition an observable presenter incarnation.

    F12 deliberately preserves the whole visible desktop, so identical content
    alone cannot prove that a new presenter produced the frame. The fixture-only
    PID suffix is the same probe used by the desktop lifecycle acceptance.
    """
    presenter = project / "src/terminal/main.lua"
    source = presenter.read_text()
    label = '"Workspace " .. names.label(workspace_id)'
    assert source.count(label) == 1, "unexpected terminal presenter label anchor"
    presenter.write_text(source.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)', 1))


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
             "version": "", "snapshot_digest": "", "artifact_digest": "", "findings": "",
             "update": False, **values})


def admit_docs_tool(project):
    """Tool metadata grants nothing: the host admits this exact operation."""
    index = project / "modules/gateway/src/api/_index.yaml"
    document = yaml.safe_load(index.read_text())
    endpoint = next(entry for entry in document["entries"] if entry["name"] == "mcp_http")
    endpoint["security"]["policies"].append("bee.agent.app.probe:docs_policy")
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
    assert report["thread_id"] == AUTHORING_THREAD, report["thread_id"]
    assert report["source_workspace"] == SOURCE_WORKSPACE, report["source_workspace"]
    assert report["thread_sequence"] > 0, report["thread_sequence"]
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
    contract names the field remedy (modules/gov/src/preflight.lua), so a
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


def open_plan(ui, label, version):
    """Read one exact staged version's plan."""
    for index in range(8):
        ui.wait("Read review", timeout=20)
        for _ in range(index):
            ui.key(b"j")
        boundary = frame_boundary(ui)
        ui.key(b"\r")
        # Reading a plan asks the destination for it and for its entry changes.
        review_header = re.compile(r"REVIEW (\S+)  version (\S+)")
        _, frame = wait_frame(ui, boundary, review_header, timeout=20)
        opened = review_header.search("\n".join(frame))
        assert opened, "the chosen staged version did not open its plan\n" + ui.text()
        if opened.group(1) == label and opened.group(2) == version:
            return boundary
        back_to_plans(ui)
    raise AssertionError("no staged plan from " + label + " at " + version + "\n" + ui.text())


def open_admitted(ui, timeout):
    """The application is chosen from the desktop's own catalog, never from a
    command line. The broker refreshes admission from the effective catalog by
    itself, so poll the catalog rather than the clock."""
    deadline = time.monotonic() + timeout
    while True:
        boundary = frame_boundary(ui)
        ui.open_start()
        if TITLE in ui.text():
            ui.choose(TITLE)
            wait_frame(ui, boundary, TITLE, timeout=timeout)
            return boundary
        ui.key(b"\x1b")
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.5)


def open_delivery(ui):
    """Enter through the ordinary desktop catalog. This also focuses the
    retained Overlays instance when another restored application is on top."""
    boundary = frame_boundary(ui)
    ui.open_start()
    ui.choose("Tools")
    ui.choose(DELIVERY)
    wait_frame(ui, boundary, "OVERLAYS", timeout=COLD_BOOT)
    return boundary


def open_activation_approval(ui, staged, proposal):
    """Select the exact pending activation by the evidence the person sees,
    never by its incidental row position among earlier requests."""
    expected = ("Asked: Establish and recover " + staged["source_workspace"]
                + " version " + staged["version"] + " in this workspace?")
    # Move to the bounded feed's first row a page at a time. This exercises the
    # ordinary list control without turning 64 individual key-pump intervals
    # into artificial UI latency.
    for _ in range(8):
        ui.key(b"\x1b[5~")
    for _ in range(64):
        boundary = frame_boundary(ui)
        ui.key(b"o")
        _, frame = wait_frame(ui, boundary, "Asked:", timeout=5)
        contents = "\n".join(frame)
        if expected in contents:
            if "Digest " + proposal not in ui.text():
                boundary = frame_boundary(ui)
                ui.key(b"t")
                wait_frame(ui, boundary, "Digest " + proposal, timeout=20)
            wait_frame(ui, boundary, "artifact_digest: " + staged["artifact_digest"], timeout=20)
            return boundary
        ui.key(b"j")
    raise AssertionError("exact activation approval is absent\n" + ui.text())


def review_and_apply(folder, project, staged, change, exercise_app, evidence, phase):
    """What the person does: read the verdict and the entry changes, accept,
    select and prepare here, approve in Approvals, and step."""
    ui = Desktop(folder, project=project)
    ui.observed_frames = []
    previous_frame = None
    try:
        initial_boundary = frame_boundary(ui)
        if not exercise_app:
            # Version one is automatic and the preceding graceful restart
            # proved its saved layout. An initial empty frame is transient
            # while that application attaches; opening the catalog there would
            # create a second instance and stop proving restoration.
            wait_frame(ui, initial_boundary, MARKER, "Count: 1", timeout=COLD_BOOT)
            geometry_boundary = frame_boundary(ui)
            ui.corners()
            previous_frame = ui.frame()
            wait_frame(ui, geometry_boundary, MARKER, "Count: 1", timeout=20)
            capture_frame(folder, evidence, ui, phase + "-previous-app", geometry_boundary, MARKER, "Count: 1")
        else:
            wait_frame(ui, initial_boundary, "No applications open", timeout=COLD_BOOT)
        # The first complete desktop frame precedes input admission by a small
        # asynchronous handoff. Wait through that handoff before opening the
        # ordinary menu; a pre-admission F1 is correctly ignored.
        ui.pump(.5)
        started = time.monotonic()
        open_delivery(ui)
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".open_delivery", started)
        maximize_boundary = frame_boundary(ui)
        ui.window_control("□")
        wait_frame(ui, maximize_boundary, "OVERLAYS", timeout=20)
        # Overlays checkpoints its active tab. A retained instance may be on
        # any pane, so select Staged by its contextual primary action. The
        # compact UI labels the tab "Staged" instead of using a pane heading.
        for _ in range(3):
            if "Read review" in ui.text() and "REVIEW " not in ui.text():
                break
            ui.key(b"\t")
        ui.wait("Read review", timeout=20)
        started = time.monotonic()
        review_boundary = open_plan(ui, staged["source_workspace"], staged["version"])
        wait_frame(ui, review_boundary, "Verdict ready", "No diagnostics and no pending migrations",
                   change + "  " + DEFINITION_ID + "  process.lua", timeout=20)
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".open_review", started)
        capture_frame(folder, evidence, ui, phase + "-review", review_boundary,
                      "REVIEW " + staged["source_workspace"],
                      "Verdict ready", change + "  " + DEFINITION_ID)
        details_boundary = frame_boundary(ui)
        ui.key(b"t")
        wait_frame(ui, details_boundary, "Artifact " + staged["artifact_digest"][:12], timeout=20)
        capture_frame(folder, evidence, ui, phase + "-review-details", details_boundary,
                      "Artifact " + staged["artifact_digest"][:12], "plan " + staged["plan_digest"][:12])
        narrow_boundary = frame_boundary(ui)
        ui.resize(80, 24)
        wait_frame(ui, narrow_boundary, "REVIEW " + staged["source_workspace"], timeout=20)
        capture_frame(folder, evidence, ui, phase + "-review-narrow", narrow_boundary,
                      "REVIEW " + staged["source_workspace"],
                      "Verdict ready")
        wide_boundary = frame_boundary(ui)
        ui.resize(100, 30)
        wait_frame(ui, wide_boundary, "REVIEW " + staged["source_workspace"], timeout=20)
        old_header = ui.screen.display[0]
        rejoin_boundary = frame_boundary(ui)
        started = time.monotonic()
        ui.key(b"\x1b[24~")
        deadline = time.monotonic() + DESKTOP_HANG_SECONDS
        while ui.screen.display[0] == old_header and time.monotonic() < deadline:
            ui.pump(.05)
        assert ui.screen.display[0] != old_header, "F12 did not replace the presenter\n" + ui.text()
        wait_frame(ui, rejoin_boundary, "REVIEW " + staged["source_workspace"],
                   "Artifact " + staged["artifact_digest"][:12], timeout=20)
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".presenter_replace", started)
        capture_frame(folder, evidence, ui, phase + "-review-rejoined", rejoin_boundary,
                      "REVIEW " + staged["source_workspace"],
                      "Artifact " + staged["artifact_digest"][:12])
        ui.key(b"a")
        ui.wait("Plan details refreshed", timeout=20)
        ui.key(b"s")
        ui.wait("Plan details refreshed", timeout=20)
        ui.key(b"p")
        ui.wait("Activation approval_bound", timeout=COLD_BOOT)
        ui.wait("proposed  proposal", timeout=20)
        proposed = re.search(r"proposed\s+proposal\s+([0-9a-f]{12})", ui.text())
        assert proposed, ui.text()

        ui.open_start()
        ui.choose("Tools")
        ui.choose(APPROVALS)
        ui.wait("APPROVALS", timeout=COLD_BOOT)
        ui.window_control("□")
        ui.pump(.4)
        ui.key(b"r")
        ui.wait("bee.gov:establish-overlay", timeout=COLD_BOOT)
        started = time.monotonic()
        approval_boundary = open_activation_approval(ui, staged, proposed.group(1))
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".open_exact_approval", started)
        capture_frame(folder, evidence, ui, phase + "-approval-details", approval_boundary,
                      "Asked: Establish and recover " + staged["source_workspace"] + " version " + staged["version"],
                      "artifact_digest: " + staged["artifact_digest"])
        confirmation_boundary = frame_boundary(ui)
        ui.key(b"a")
        wait_frame(ui, confirmation_boundary, "Approve this request?", timeout=20)
        capture_frame(folder, evidence, ui, phase + "-approval-confirmation", confirmation_boundary,
                      "Approve this request?")
        started = time.monotonic()
        approved_boundary = frame_boundary(ui)
        ui.key(b"\t")
        ui.key(b"\r")
        wait_frame(ui, approved_boundary, "approved by bee.application:", timeout=COLD_BOOT)
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".approve", started)

        delivery_boundary = frame_boundary(ui)
        focus(ui, DELIVERY)
        wait_frame(ui, delivery_boundary, "REVIEW " + staged["source_workspace"], timeout=20)
        started = time.monotonic()
        apply_boundary = frame_boundary(ui)
        for _ in range(8):
            step_boundary = frame_boundary(ui)
            ui.key(b"x")
            _, step_frame = wait_frame(ui, step_boundary,
                                       re.compile(r"\n Activation (?:consuming|authorized|applying|settled)\b"),
                                       timeout=COLD_BOOT)
            if "settled  applied" in "\n".join(step_frame):
                break
        wait_frame(ui, apply_boundary, "settled  applied", "consumed  proposal",
                   "Receipt  overlay " + OVERLAY_OWNER,
                   "Receipt  artifact " + staged["artifact_digest"][:12], timeout=COLD_BOOT)
        # The overlay is the activation owner's own receipt.
        record_seconds(folder, evidence, "local_ui_seconds", phase + ".apply", started)
        capture_frame(folder, evidence, ui, phase + "-applied", apply_boundary, "settled  applied",
                      "Receipt  overlay " + OVERLAY_OWNER, "Receipt  artifact " + staged["artifact_digest"][:12])

        if exercise_app:
            # The applied definition is opened from the desktop's own catalog.
            started = time.monotonic()
            app_boundary = open_admitted(ui, COLD_BOOT)
            wait_frame(ui, app_boundary, MARKER, "Count: 0", timeout=COLD_BOOT)
            record_seconds(folder, evidence, "local_ui_seconds", phase + ".open_authored_app", started)
            ui.wait("Count: 0")
            capture_frame(folder, evidence, ui, phase + "-app-initial", app_boundary, MARKER, "Count: 0")
            started = time.monotonic()
            checkpoint_boundary = frame_boundary(ui)
            ui.key(b"x")
            # The counter the window shows is the one the broker committed.
            wait_frame(ui, checkpoint_boundary, "Count: 1", "Saved: 1", timeout=20)
            record_seconds(folder, evidence, "local_ui_seconds", phase + ".checkpoint", started)
            capture_frame(folder, evidence, ui, phase + "-app-saved", checkpoint_boundary,
                          MARKER, "Count: 1", "Saved: 1")
        else:
            started = time.monotonic()
            updated_boundary = frame_boundary(ui)
            focus(ui, TITLE)
            wait_frame(ui, updated_boundary, UPDATE_MARKER, "Count: 1", timeout=COLD_BOOT)
            assert previous_frame is not None and ui.frame() == previous_frame, (
                "definition update reset the existing window geometry", previous_frame, ui.frame(), ui.text())
            record_seconds(folder, evidence, "local_ui_seconds", phase + ".live_update", started)
            capture_frame(folder, evidence, ui, phase + "-app-updated-live", updated_boundary,
                          UPDATE_MARKER, "Count: 1")
        ui.quit()
    finally:
        ui.close()


def restore(folder, project, evidence):
    restarted = Desktop(folder, project=project)
    restarted.observed_frames = []
    try:
        boundary = frame_boundary(restarted)
        started = time.monotonic()
        focus(restarted, TITLE)
        wait_frame(restarted, boundary, MARKER, "Count: 1", timeout=COLD_BOOT)
        record_seconds(folder, evidence, "local_ui_seconds", "v1.restore", started)
        capture_frame(folder, evidence, restarted, "v1-restored", boundary, MARKER, "Count: 1")
        restarted.open_start()
        assert TITLE in restarted.text(), restarted.text()
        restarted.key(b"\x1b")
        restarted.pump(.5)
        restarted.quit()
    finally:
        restarted.close()


def restore_updated(folder, project, evidence):
    restarted = Desktop(folder, project=project)
    restarted.observed_frames = []
    try:
        boundary = frame_boundary(restarted)
        started = time.monotonic()
        focus(restarted, TITLE)
        wait_frame(restarted, boundary, UPDATE_MARKER, "Count: 1", timeout=COLD_BOOT)
        record_seconds(folder, evidence, "local_ui_seconds", "v2.restore", started)
        capture_frame(folder, evidence, restarted, "v2-restored", boundary, UPDATE_MARKER, "Count: 1")
        restarted.quit()
    finally:
        restarted.close()


def exercise():
    review_contract_check()
    bind_host()
    folder = evidence_root()
    evidence = ui_evidence(folder)
    print("Private evidence:", folder)
    project = folder / "project"
    shutil.copytree(ROOT / "src", project / "src")
    shutil.copytree(ROOT / "modules", project / "modules")
    stamp_presenter(project)
    shutil.copytree(ROOT / "tests/fixtures/agent_app", project / "src/probe")
    if os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_FIXTURE") == "1":
        # The replica fixture supplies an enrolled supervisor explicitly.
        # Keep the real Hive sender in bee.hive and disable only the protected
        # service entry for this fixture's explicitly managed supervisor.
        hive_host_index = project / "src/hive/service/_index.yaml"
        hive_host = yaml.safe_load(hive_host_index.read_text())
        service = next(item for item in hive_host["entries"] if item["name"] == "supervisor_service")
        service["lifecycle"]["auto_start"] = False
        hive_host_index.write_text(yaml.safe_dump(hive_host, sort_keys=False))
        shutil.copytree(ROOT / "tests/fixtures/hive_replica", project / "src/replica_probe")
        shutil.rmtree(project / "src/replica_probe/host_environment")
        source_probe = project / "src/replica_probe/_index.yaml"
        probe = yaml.safe_load(source_probe.read_text())
        controller = next(item for item in probe["entries"] if item["name"] == "controller_policy")
        controller["policy"]["actions"] = [action for action in controller["policy"]["actions"]
                                              if not action.startswith("registry.overlay.")]
        source_probe.write_text(yaml.safe_dump(probe, sort_keys=False))
    for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
        shutil.copy2(ROOT / name, project / name)
    configure_source_node(project)
    stage_material(project)
    set_variable(project, "modules/driver-agy/src/_index.yaml", "executable", "BEE_AGENT_APP_AGY")
    set_variable(project, "src/env/_index.yaml", "machine_home", "BEE_AGENT_APP_HOME")
    admit_docs_tool(project)
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
    workspace_id = classic_workspace(folder / "workspace.db")
    configure_continuous_source(project, workspace_id)
    if os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_FIXTURE") == "1":
        lint(project, "continuous-source")

    findings, report, staged = "", None, None
    source_workspace = SOURCE_WORKSPACE
    for round_number in range(1, ROUNDS + 1):
        label = str(round_number)
        write_inputs(project, round=label, source_workspace=source_workspace,
                     launch_workspace=workspace_id, findings=findings)
        started = time.monotonic()
        report = author(project, folder, label)
        record_seconds(folder, evidence, "provider_seconds", "v1.round-" + label, started)
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
    assert source_workspace == staged["source_workspace"], staged

    assert [item["id"] for item in staged["added"]] == [DEFINITION_ID], staged["added"]
    assert staged["changed"] == [], staged["changed"]
    assert staged["overlay_owner"] == OVERLAY_OWNER, staged
    review_and_apply(folder, project, staged, "added", True, evidence, "v1")
    restore(folder, project, evidence)
    initial_identity = saved_app_identity(folder)
    first_revision = report["workspace_revision"]

    if os.environ.get("BEE_AGENT_APP_SINGLE_VERSION") == "1":
        (folder / "authored.json").write_text(json.dumps({"initial": {
            "snapshot_digest": report["snapshot_digest"], "artifact_digest": report["artifact_digest"],
            "plan_digest": staged["plan_digest"], "workspace_revision": first_revision}, "updated": {
            "snapshot_digest": report["snapshot_digest"], "artifact_digest": report["artifact_digest"],
            "plan_digest": staged["plan_digest"], "workspace_revision": first_revision},
            "published_version": staged["version"], "application_marker": MARKER,
            "source_workspace": source_workspace, "thread_id": AUTHORING_THREAD,
            "source_node": staged["source_node"], "workspace_id": workspace_id,
            "application_identity": {"view_id": initial_identity[0], "instance_id": initial_identity[1]},
            "entries": report["entries"]}, indent=2))
        print("Agent-authored application: the managed Agy authored, locally reviewed, approved, applied, opened and restored "
              + DEFINITION_ID + " as " + staged["version"] + "; evidence in " + str(folder))
        return

    updated, findings = None, ""
    for update_number in range(1, UPDATE_ROUNDS + 1):
        label = "update" if update_number == 1 else "update-" + str(update_number)
        write_inputs(project, round=label, source_workspace=source_workspace,
                     launch_workspace=workspace_id, update=True, findings=findings)
        started = time.monotonic()
        updated = author(project, folder, label)
        record_seconds(folder, evidence, "provider_seconds", "v2." + label, started)
        findings = contract_findings(updated) or candidate_findings(folder, project, updated["entries"], label) or ""
        if not findings:
            break
        print("Update " + label + " returns to the agent: " + findings.splitlines()[0])
    assert updated is not None and not findings, "the agent did not reach a ready update in " + str(UPDATE_ROUNDS) + " rounds: " + findings
    assert updated["workspace_revision"] > first_revision, updated
    assert updated["thread_sequence"] > report["thread_sequence"], updated
    assert updated["snapshot_digest"] != report["snapshot_digest"], updated
    assert updated["artifact_digest"] != report["artifact_digest"], updated
    application = updated["entries"][0]["meta"]["application"]
    assert application["revision"] == "2", application
    write_inputs(project, round="update", source_workspace=source_workspace,
                 launch_workspace=workspace_id, destination_workspace=workspace_id,
                 version="2.0.0", snapshot_digest=updated["snapshot_digest"],
                 artifact_digest=updated["artifact_digest"], update=True)
    updated_stage = stage(project, folder, "update")
    assert not preflight_findings(updated_stage), preflight_findings(updated_stage)
    assert updated_stage["added"] == [], updated_stage["added"]
    assert [item["id"] for item in updated_stage["changed"]] == [DEFINITION_ID], updated_stage["changed"]
    assert updated_stage["source_workspace"] == staged["source_workspace"] == source_workspace
    assert updated_stage["overlay_owner"] == staged["overlay_owner"] == OVERLAY_OWNER
    review_and_apply(folder, project, updated_stage, "changed", False, evidence, "v2")
    assert saved_app_identity(folder) == initial_identity, "definition update replaced the logical application identity"
    restore_updated(folder, project, evidence)
    assert saved_app_identity(folder) == initial_identity, "restart replaced the logical application identity"

    (folder / "authored.json").write_text(json.dumps({"initial": {
        "snapshot_digest": report["snapshot_digest"], "artifact_digest": report["artifact_digest"],
        "plan_digest": staged["plan_digest"], "workspace_revision": first_revision}, "updated": {
        "snapshot_digest": updated["snapshot_digest"], "artifact_digest": updated["artifact_digest"],
        "plan_digest": updated_stage["plan_digest"], "workspace_revision": updated["workspace_revision"]},
        "source_workspace": source_workspace, "thread_id": AUTHORING_THREAD,
        "source_node": updated_stage["source_node"], "workspace_id": workspace_id,
        "application_identity": {"view_id": initial_identity[0], "instance_id": initial_identity[1]},
        "entries": updated["entries"]}, indent=2))
    print("Agent-authored application: a live managed Agy attempt authored " + DEFINITION_ID
          + " through the scoped Governance MCP overlay tool and froze it as "
          + report["snapshot_digest"][:12] + " (artifact " + report["artifact_digest"][:12]
          + "), typed lint passed, the destination staged it as plan " + staged["plan_digest"][:12]
          + " with a ready preflight, a person reviewed, selected, prepared and approved it, "
          + OVERLAY_OWNER + " applied the overlay, then the same managed thread revision-edited workspace "
          + source_workspace + " into " + updated["snapshot_digest"][:12] + ", a person independently reviewed "
            "and approved version 2.0.0 into the same overlay, and the updated application restored its state; "
            "evidence in " + str(folder))


if __name__ == "__main__":
    exercise()

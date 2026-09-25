"""Carry one authored application to an open window that survives a restart.

An application definition is authored into a governed overlay, frozen with
its digest, published, discovered, staged, preflighted, reviewed, selected,
approved, consumed and applied by the registry owner through the production
governance chain (bee.gov.binding:overlay_call, publication_call,
destination_call and the approvals owner). The application then appears in the
desktop's effective catalog, opens from it as a real window with its own
content, and comes back with its state after a full host restart.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import (ROOT, RUNTIME, classic_workspace, configure_managed_gateway,
                       database_environment, deployment_copy, pack_deployment, workspace_checkpoint)  # noqa: E402

DEFINITION_ID = "bee.app_journey_demo:app"
TITLE = "App Journey"
GUIDE_DEFINITION_ID = "app.counter:app"
GUIDE_TITLE = "Counter App"
GUIDE_WORKSPACE = "counter"
GUIDE_VERSION = "1.0.0"
# The shipped approver policy of the workspace-application host profile.
GUIDE_APPROVAL_POLICY = "workspace-application-delivery"
# The cold first boot of a full composition, the budget the sibling desktop
# acceptances (tests/inbox_decide.py) already use for one.
COLD_BOOT = 30
OVERLAY_WRITE = "registry.overlay.apply"
OVERLAY_OWNER = "bee.app.journey.probe:activation_overlay"
OPEN_SEED = "bee.app.open.probe:seed"
OPEN_PROBE_THREAD = "open-probe-thread"
MIGRATION_ID = "bee.app_journey_demo:001"


def assert_shared_database(root):
    """The host database keeps its unrelated row and one prefixed app table."""
    path = Path(root) / ".wippy/app-journey-shared.db"
    assert path.exists(), path
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT id FROM _migrations ORDER BY id").fetchall() == [(MIGRATION_ID,)]
        assert db.execute("SELECT value FROM journey_items ORDER BY id").fetchall() == [("journey",)]
        assert db.execute("SELECT value FROM other_items").fetchall() == [("preserved",)]
        assert db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='items'").fetchall() == []


def bind_admission(project):
    """The host owner admits the definition; registry metadata cannot."""
    index = project / "src/security/_index.yaml"
    document = yaml.safe_load(index.read_text())
    admission = next(entry for entry in document["entries"] if entry["name"] == "application_admission")
    admission["bindings"].append({"definition_id": DEFINITION_ID,
                                  "policies": ["bee.security:ordinary_app_subsystem_boundary",
                                               "bee.app.open.probe:recheck_policy",
                                               "bee.app.open.probe:operator_signal_policy"],
                                  "thread_access": "observe_post"})
    window = next(item for item in admission["bindings"]
                  if item["definition_id"] == "bee.harness.window:app")
    window["thread_access"] = "observe_post"
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def assert_overlay_authority(project):
    """Overlays belong to the destination owner: nothing else may write one."""
    granted, denied = set(), set()
    indexes = list((project / "src").rglob("_index.yaml")) + list((project / "modules/gov/src").rglob("_index.yaml"))
    for index in indexes:
        document = yaml.safe_load(index.read_text())
        for entry in document.get("entries", []):
            policy = entry.get("policy")
            if not isinstance(policy, dict) or OVERLAY_WRITE not in (policy.get("actions") or []):
                continue
            identity = f'{document["namespace"]}:{entry["name"]}'
            (granted if policy.get("effect") == "allow" else denied).add(identity)
    assert granted == {"bee.gov.security:destination_service_policy"}, granted
    assert denied == {"bee.security:app_boundary_policy", "bee.security:scope_managing_app_boundary"}, denied


def assert_delivery_has_no_overlay_authority(project):
    """The agent's delivery and publish surfaces reach publication and
    destination staging; they grant no overlay write, which is the activation
    owner's alone."""
    wanted = {"bee.security.gateway:gateway_tool_delivery_policy", "bee.security.gateway:gateway_tool_publish_policy",
              "bee.gov.security:delivery_facade_policy"}
    seen = set()
    indexes = list((project / "src").rglob("_index.yaml")) + list((project / "modules/gov/src").rglob("_index.yaml"))
    for index in indexes:
        document = yaml.safe_load(index.read_text())
        for entry in document.get("entries", []):
            identity = f'{document["namespace"]}:{entry["name"]}'
            if identity not in wanted:
                continue
            seen.add(identity)
            actions = (entry.get("policy") or {}).get("actions") or []
            assert OVERLAY_WRITE not in actions, identity
            for resource in (entry.get("policy") or {}).get("resources") or []:
                assert "overlay" not in resource, (identity, resource)
    assert seen == wanted, sorted(wanted - seen)


def open_admitted(ui, timeout):
    """Boot recovery re-establishes the activation owner's overlay after the
    desktop is already up; the broker then refreshes admission from the
    effective catalog by itself, so poll the catalog rather than the clock."""
    deadline = time.monotonic() + timeout
    while True:
        ui.open_start()
        if TITLE in ui.text():
            ui.choose(TITLE)
            return
        ui.key(b"\x1b")
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.5)


def deliver(project, folder, deployment=None):
    if deployment:
        deployment_copy(deployment, folder)
    args = [str(RUNTIME), "run", "--verbose", "app-journey-deliver", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=folder if deployment else project, capture_output=True, text=True,
                            timeout=300, env=database_environment(
                                folder, BEE_APP_JOURNEY_WORKSPACE=classic_workspace(Path(folder) / "workspace.db")))
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "APP_JOURNEY_DELIVERED" in output, output
    match = re.search(r"APP_JOURNEY_DELIVERED\s+(\{.*\})", output)
    assert match, output
    evidence = json.loads(match.group(1))
    for name in ("artifact_digest", "snapshot_digest", "plan_digest", "preflight_digest", "proposal_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), (name, evidence)
    assert evidence["admitted_title"] == TITLE, evidence
    assert evidence["overlay_owner"] == OVERLAY_OWNER, evidence
    assert evidence["refused_overlay_write"] == \
        "not allowed to apply registry overlay: bee.app.journey.probe:forbidden_overlay", evidence
    return evidence


def stage_replacement(project, folder):
    """Author and stage a compatible replacement while the desktop is live.

    The fixture command stops after publication and durable staging. Review,
    selection, approval and application remain the ordinary UI flow below.
    """
    result = subprocess.run([str(RUNTIME), "run", "--verbose", "app-journey-stage", "--host", "bee:workers",
                             "--override", "bee.managed:listener:addr=127.0.0.1:0",
                             "--set", f"registry.history_path={folder}/registry.db"], cwd=project,
                            capture_output=True, text=True, timeout=300, env=database_environment(folder))
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "APP_JOURNEY_REPLACEMENT_STAGED" in output, output
    match = re.search(r"APP_JOURNEY_REPLACEMENT_STAGED\s+(\{.*\})", output)
    assert match, output
    evidence = json.loads(match.group(1))
    for name in ("snapshot_digest", "artifact_digest", "plan_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), evidence
    assert evidence["version"] == "1.0.1" and evidence["workspace"] == "app-journey-source", evidence
    return evidence


def apply_staged_in_ui(ui, staged, root, expected_capability=None):
    """Review, approve and apply one exact staged plan through the UI."""
    ui.open_start()
    ui.choose("Tools")
    ui.choose("Overlays")
    ui.wait("OVERLAYS", timeout=COLD_BOOT)
    ui.pump(.5)
    ui.key(b"\t")
    ui.key(b"f")
    ui.wait(staged["workspace"], timeout=20)
    ui.wait("Read review", timeout=20)
    ui.key(b"j")
    ui.key(b"\r")
    try:
        ui.wait("REVIEW " + staged["workspace"], timeout=20)
    except AssertionError:
        Path("/tmp/app-journey-replacement-desktop.raw").write_bytes(ui.raw)
        raise
    ui.wait("Verdict ready", timeout=20)
    ui.wait("Accept review", timeout=20)
    ui.key(b"a")
    ui.wait("Select version", timeout=20)
    ui.key(b"s")
    ui.wait("Request approval", timeout=20)
    ui.key(b"p")
    ui.wait("Activation approval_bound", timeout=COLD_BOOT)

    ui.open_start()
    ui.choose("Tools")
    ui.choose("Approvals")
    ui.wait("APPROVALS", timeout=COLD_BOOT)
    ui.window_control("□")
    ui.pump(.5)
    ui.key(b"r")
    ui.wait("bee.gov:establish-overlay", timeout=COLD_BOOT)
    expected = ("Asked: Establish and recover " + staged["workspace"]
                + " version " + staged["version"] + " in this workspace?")
    for _ in range(8):
        ui.key(b"\x1b[5~")
    for _ in range(64):
        ui.key(b"o")
        ui.wait("Asked:", timeout=5)
        if expected in ui.text():
            break
        ui.key(b"j")
    else:
        raise AssertionError("exact replacement approval is absent\n" + ui.text())
    if expected_capability:
        ui.wait("Change: added: " + expected_capability, timeout=20)
        ui.wait("Capability: " + expected_capability, timeout=20)
    ui.key(b"a")
    ui.wait("Approve this request?", timeout=20)
    ui.key(b"\t")
    ui.key(b"\r")
    ui.wait("approved by bee.application:", timeout=COLD_BOOT)
    assert_inbox_decider(root, classic_workspace(Path(root) / "workspace.db"), staged["approval_policy"])

    # Focus the retained delivery window from the taskbar and let its own
    # activation loop consume the one approved effect.
    deadline = time.monotonic() + 10
    while "Overlays" not in ui.screen.display[0]:
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.2)
    x = ui.screen.display[0].index("Overlays") + 1
    ui.mouse(0, x, 1)
    ui.mouse(0, x, 1, True)
    ui.pump(.4)
    for _ in range(8):
        ui.key(b"x")
        ui.pump(.1)
        deadline = time.monotonic() + COLD_BOOT
        while "Working…" in ui.text() or "Request in progress" in ui.text():
            assert time.monotonic() < deadline, ui.text()
            ui.pump(.1)
        if "Activation settled" in ui.text(): break
    ui.wait("Activation settled", timeout=COLD_BOOT)
    ui.window_control("×")
    ui.pump(.3)
    ui.window_control("×")
    ui.pump(.3)


def replace_v2_in_ui(ui, staged, root):
    """Review, approve and apply one exact compatible plan through the UI."""
    staged = dict(staged, approval_policy="local-app-journey")
    apply_staged_in_ui(ui, staged, root)


def guide(project, folder):
    """The guide's own example, authored through the real chain, must reach a
    ready preflight. This is what keeps the product guide from rotting: the
    same value an agent reads over MCP is published and staged here."""
    args = [str(RUNTIME), "run", "--verbose", "app-journey-guide", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(
                                folder, BEE_APP_JOURNEY_WORKSPACE=classic_workspace(Path(folder) / "workspace.db")))
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    match = re.search(r"APP_JOURNEY_GUIDE\s+(\{.*\})", output)
    assert match, output
    evidence = json.loads(match.group(1))
    for name in ("snapshot_digest", "artifact_digest", "plan_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), (name, evidence)
    assert evidence["ready"] is True and evidence["example_matches"] is True, evidence
    assert evidence["definition_id"] == GUIDE_DEFINITION_ID, evidence
    evidence["workspace"] = GUIDE_WORKSPACE
    evidence["version"] = GUIDE_VERSION
    evidence["approval_policy"] = GUIDE_APPROVAL_POLICY
    return evidence


def inspect(project, folder):
    """A separate boot must compose the reviewed definition and admit it."""
    args = [str(RUNTIME), "run", "--verbose", "app-journey-inspect", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(
                                folder, BEE_APP_JOURNEY_WORKSPACE=classic_workspace(Path(folder) / "workspace.db")))
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    match = re.search(r"APP_JOURNEY_COMPOSED\s+(\{.*\})", output)
    assert match, output
    composed = json.loads(match.group(1))
    assert composed["entry_present"] is True and composed["admitted_title"] == TITLE, composed


def add_open_admission(project):
    """Admit the gateway seed alongside the authored journey application."""
    index = project / "src/security/_index.yaml"
    document = yaml.safe_load(index.read_text())
    admission = next(entry for entry in document["entries"]
                     if entry["name"] == "application_admission")
    admission["bindings"].append({
        "definition_id": OPEN_SEED,
        "policies": ["bee.app.open.probe:view_policy", "bee.app.open.probe:host_lookup_policy",
                      "bee.app.open.probe:evidence_policy", "bee.app.open.probe:operator_signal_policy"]})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def open_catalog_app(ui, title, timeout):
    """Open a named admitted application from the desktop catalog."""
    deadline = time.monotonic() + timeout
    while True:
        ui.open_start()
        if title in ui.text():
            ui.choose(title)
            return
        ui.key(b"\x1b")
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.5)


def wait_taskbar_title(ui, title, timeout):
    """Return the exact title span after its taskbar tab is rendered."""
    expected = re.compile(rf"(?<!\S){re.escape(title)}(?!\S)")
    deadline = time.monotonic() + timeout
    while True:
        tab = ui.screen.display[0]
        match = expected.search(tab)
        if match:
            return match.start() + 1
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.1)


def wait_agent_picker_choice(ui, title, timeout):
    """Wait for the Agent picker and return its exact profile row."""
    deadline = time.monotonic() + timeout
    while True:
        rows = ui.screen.display
        picker = any(re.search(r"(?<!\S)AGENT(?!\S)", line) for line in rows)
        chooser = any("Choose a profile" in line for line in rows)
        if picker and chooser:
            matches = [(line.index(title) + 1, row) for row, line in enumerate(rows, 1) if title in line]
            if len(matches) == 1:
                return matches[0]
        assert time.monotonic() < deadline, ui.text()
        ui.pump(.1)


def configure_open_agent(project):
    """Bind the scripted executable at the fixture edge; the managed carrier
    still owns gateway admission, materialization and revocation."""
    index = project / "src/open_probe/_index.yaml"
    document = yaml.safe_load(index.read_text())
    policy = next(entry for entry in document["entries"] if entry["name"] == "managed_agent_policy")
    policy["data"]["executables"] = {"claude": str(ROOT / "tests/fixtures/harness/bin/claude")}
    policy["data"]["environment"]["BEE_FIXTURE_STREAM"] = \
        str(ROOT / "tests/fixtures/drivers/claude/stream-json-2/plain.jsonl")
    policy["data"]["environment"]["BEE_FIXTURE_WINDOW_DEFINITION"] = "bee.harness.window:app"
    harness = project / "src/_index.yaml"
    harness_document = yaml.safe_load(harness.read_text())
    activation = next(entry for entry in harness_document["entries"] if entry["name"] == "harness_activation")
    activation["data"]["bindings"].append("bee.window.hooks.fixture:binding")
    harness.write_text(yaml.safe_dump(harness_document, sort_keys=False))
    hooks = project / "src/window_hooks/_index.yaml"
    hooks_document = yaml.safe_load(hooks.read_text())
    definition = next(entry for entry in hooks_document["entries"] if entry["name"] == "definition")
    definition["data"]["presentation"]["start_menu"] = True
    definition["data"].pop("session_resource")
    hooks.write_text(yaml.safe_dump(hooks_document, sort_keys=False))
    index.write_text(yaml.safe_dump(document, sort_keys=False))

    approvals = project / "src/_index.yaml"
    approval_document = yaml.safe_load(approvals.read_text())
    approvers = next(entry for entry in approval_document["entries"]
                     if entry["name"] == "approver_policies")
    approvers["policies"].append({"name": "app-open-runtime",
                                  "approvers": ["bee.app_open.operator"],
                                  "max_ttl_ms": 60000})
    approvals.write_text(yaml.safe_dump(approval_document, sort_keys=False))


def run_open_probe(project, directory, packed=False, deployment=None):
    """Call application_open over the real loopback MCP endpoint."""
    Path(directory).mkdir(parents=True, exist_ok=True)
    report_path = (Path(directory) if packed else project) / "evidence/open.json"
    report_path.unlink(missing_ok=True)
    ui = Desktop(directory, packed=packed, project=project, deployment=deployment)
    try:
        try:
            ui.wait("No applications open", timeout=COLD_BOOT)
            deadline = time.monotonic() + COLD_BOOT
            while True:
                ui.open_start()
                if TITLE in ui.text():
                    ui.choose("Open Probe")
                    break
                ui.key(b"\x1b")
                assert time.monotonic() < deadline, ui.text()
                ui.pump(.5)
            deadline = time.monotonic() + 40
            progress = {}
            while progress.get("passed") is not True:
                ui.pump()
                if report_path.exists():
                    try:
                        progress = json.loads(report_path.read_text())
                    except json.JSONDecodeError:
                        progress = {}
                    assert progress.get("passed") is not False, progress
                if time.monotonic() >= deadline or ui.process.poll() is not None:
                    raise AssertionError(f"open probe did not complete: {progress}")
            assert progress.get("window_id") and progress.get("window_instance"), progress

            # The window was opened by the approved MCP caller. Select its
            # real picker and child through the desktop, then prove the hook
            # driver remains a usable PTY after gateway delivery.
            agent_x = wait_taskbar_title(ui, "Agent", timeout=10)
            ui.mouse(0, agent_x, 1)
            ui.mouse(0, agent_x, 1, True)
            fixture_x, fixture_row = wait_agent_picker_choice(ui, "Window hooks fixture", timeout=10)
            ui.mouse(0, fixture_x, fixture_row)
            ui.mouse(0, fixture_x, fixture_row, True)
            ui.key(b"\r")
            ui.wait("HOOK_TOOL:http-202", timeout=20)
            ui.key(b"first-pty-check\r")
            ui.wait("HOOK_CHILD_INPUT:first-pty-check", timeout=10)
            ui.wait("Window hooks fixture · Using tool", timeout=10)
            ui.key(b"second-pty-check\r")
            ui.wait("HOOK_CHILD_INPUT:second-pty-check", timeout=10)

            deadline = time.monotonic() + 10
            while "APP JOURNEY DELIVERED" not in ui.text():
                tabs = ui.screen.display[0]
                app_x = tabs.index("App Journey") + 1
                ui.mouse(0, app_x, 1)
                ui.mouse(0, app_x, 1, True)
                assert time.monotonic() < deadline, ui.text()
            ui.wait("Saved: 0")
            ui.key(b"x")
            ui.wait("Saved: 1")
        except AssertionError as problem:
            evidence = report_path
            detail = evidence.read_text() if evidence.exists() else "missing"
            raise AssertionError(f"{problem}; open evidence={detail}") from problem
        ui.quit()
    finally:
        ui.close()
    assert report_path.exists(), f"open probe did not write evidence: {ui.text()}"
    report = json.loads(report_path.read_text())
    assert report["passed"] is True, report
    assert report["first_id"] and report["second_id"], report
    assert report["first_id"] != report["second_id"], report
    assert report["first_instance"] != report["second_instance"], report
    assert report["access_approval_id"], report
    assert report["unapproved_refused"] is True and report["agent_exited"] is True, report
    assert report["first_thread_proof"]["instance_id"] == report["first_instance"], report
    assert report["second_thread_proof"]["instance_id"] == report["second_instance"], report
    assert report["removed_instance"] == report["first_instance"] and report["removed_access"] == "denied", report
    assert report["surviving_instance"] == report["second_instance"] and report["surviving_access"] == "active", report
    assert report["direct_sender_refused"] is True, report
    restarted = Desktop(directory, packed=packed, project=project, deployment=deployment)
    try:
        restarted.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
        restarted.wait("Count: 1")
        restarted.wait("Saved: 1")
        restarted.wait("Access: pending")
        restarted.key(b"r")
        restarted.wait("Access: active")
        restarted.quit()
    finally:
        restarted.close()
    return report


def copy_activation(source, destination):
    """Clone approved durable state; boot recovery must reapply its overlay."""
    for name in ("registry", "governance", "approvals", "workspace"):
        with sqlite3.connect(source / f"{name}.db") as origin:
            with sqlite3.connect(destination / f"{name}.db") as target:
                origin.backup(target)


def binding_rows(root, instance_ids):
    with sqlite3.connect(Path(root) / "workspace.db") as db:
        rows = db.execute(
            "SELECT instance_id, state, cleanup_pending FROM workspace_application_thread_bindings "
            f"WHERE instance_id IN ({','.join('?' for _ in instance_ids)}) ORDER BY instance_id",
            tuple(instance_ids)).fetchall()
    return {instance_id: (state, cleanup_pending)
            for instance_id, state, cleanup_pending in rows}


def binding_records(root, instance_ids):
    with sqlite3.connect(Path(root) / "workspace.db") as db:
        rows = db.execute(
            "SELECT instance_id, thread_id, actor_id, state, membership_revision, cleanup_pending "
            "FROM workspace_application_thread_bindings "
            f"WHERE instance_id IN ({','.join('?' for _ in instance_ids)}) ORDER BY instance_id",
            tuple(instance_ids)).fetchall()
    return {row[0]: row[1:] for row in rows}


def thread_members(root, actor_ids):
    with sqlite3.connect(Path(root) / "threads.db") as db:
        rows = db.execute(
            "SELECT actor, revision, active FROM bee_thread_members "
            f"WHERE actor IN ({','.join('?' for _ in actor_ids)}) ORDER BY actor",
            tuple(actor_ids)).fetchall()
    return {actor: (revision, active) for actor, revision, active in rows}


def wait_binding(root, instance_ids, predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        rows = binding_rows(root, instance_ids)
        selected = predicate(rows)
        if selected is not None:
            return selected
        assert time.monotonic() < deadline, rows
        time.sleep(.02)


def saved_instances(root):
    return {item["instance_id"] for item in workspace_checkpoint(Path(root) / "workspace.db")["applications"]}


def saved_application(root, instance_id):
    matches = [item for item in workspace_checkpoint(Path(root) / "workspace.db")["applications"]
               if item["instance_id"] == instance_id]
    assert len(matches) == 1, (instance_id, matches)
    return matches[0]


def assert_inbox_decider(root, workspace_id, policy="local-app-journey"):
    """The Start-menu Approvals app decides as its private broker principal."""
    with sqlite3.connect(Path(root) / "approvals.db") as db:
        row = db.execute(
            "SELECT decider_id, proposal_digest FROM bee_approval_requests "
            "WHERE policy = ? AND state = 'decided' "
            "ORDER BY created_at DESC LIMIT 1", (policy,)).fetchone()
    assert row and re.fullmatch(
        rf"bee\.application:{re.escape(workspace_id)}:[0-9a-f-]+", row[0]), row
    checkpoint = saved_application(root, row[0].rsplit(":", 1)[1])
    assert checkpoint["definition_id"] == "bee.approvals.inbox:app", checkpoint


def revoke_crash_recovery(project, source_root, report, destination):
    """Crash after the durable revoke fence and before Threads leave.

    The pause exists only in this disposable source copy. Production receives
    no test switch or timing branch.
    """
    shutil.copytree(source_root, destination)
    host = project / "src/host/main.lua"
    original = host.read_text()
    anchor = "            value, operation_error = database.thread_bindings:begin_revoke(request.value)\n"
    assert original.count(anchor) == 1
    host.write_text(original.replace(
        anchor,
        anchor + "            if value and not operation_error then while true do time.sleep(\"1s\") end end\n"))
    instance_ids = [report["surviving_instance"]]
    ui = Desktop(destination, project=project)
    try:
        ui.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
        initial = binding_rows(destination, instance_ids)
        assert set(initial) == set(instance_ids) and all(
            value == ("active", 0) for value in initial.values()), initial
        ui.window_control("×")
        revoked = wait_binding(
            destination, instance_ids,
            lambda rows: next((instance_id for instance_id, value in rows.items()
                               if value == ("revoked", 1)), None))
        assert ui.process.poll() is None and "APP JOURNEY DELIVERED" in ui.text(), ui.text()
    finally:
        ui.close()
        host.write_text(original)

    restarted = Desktop(destination, project=project)
    try:
        restarted.wait("No applications open", timeout=COLD_BOOT)
        wait_binding(destination, instance_ids,
                     lambda rows: revoked if rows.get(revoked) == ("revoked", 0) else None)
        assert revoked not in saved_instances(destination)
        # Catalog readiness is the user-visible owner-ready boundary; the
        # empty desktop can render before all startup services settle.
        deadline = time.monotonic() + COLD_BOOT
        while True:
            restarted.open_start()
            if TITLE in restarted.text():
                restarted.key(b"\x1b")
                break
            restarted.key(b"\x1b")
            assert time.monotonic() < deadline, restarted.text()
            restarted.pump(.1)
        restarted.quit()
    finally:
        restarted.close()


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-app-journey-") as directory, \
            patch.dict(os.environ, {"WIPPY_NODE_ID": Path(directory).name}):
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        shutil.copytree(ROOT / "tests/fixtures/app_journey", project / "src/probe")
        shutil.copytree(ROOT / "tests/fixtures/app_open", project / "src/open_probe")
        shutil.copytree(ROOT / "tests/fixtures/window_hooks", project / "src/window_hooks")
        open_manifest = yaml.safe_load((project / "src/open_probe/_index.yaml").read_text())
        open_seed = next(entry for entry in open_manifest["entries"] if entry["name"] == "seed")
        assert open_seed["imports"]["client"] == "bee.application:client"
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        bind_admission(project)
        add_open_admission(project)
        configure_open_agent(project)
        shutil.copytree(ROOT / "tests/fixtures/modules/gateway/src/managed", project / "src/managed")
        configure_managed_gateway(project)
        assert_overlay_authority(project)
        assert_delivery_has_no_overlay_authority(project)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                        "--set", "lua.type_system.strict=true"], cwd=project, check=True, timeout=300)
        initial = Desktop(folder, project=project)
        try:
            initial.wait("No applications open", timeout=COLD_BOOT)
            initial.quit()
        finally:
            initial.close()
        # The exact Guide example owns a durable overlay and application
        # checkpoint. Exercise it against a separate workspace so its accepted
        # desired state cannot alter the replacement journey below.
        guide_root = folder / "guide"
        guide_root.mkdir()
        guide_initial = Desktop(guide_root, project=project)
        try:
            guide_initial.wait("No applications open", timeout=COLD_BOOT)
            guide_initial.quit()
        finally:
            guide_initial.close()
        guide_evidence = guide(project, guide_root)
        guide_ui = Desktop(guide_root, project=project)
        try:
            guide_ui.wait("No applications open", timeout=COLD_BOOT)
            apply_staged_in_ui(guide_ui, guide_evidence, guide_root)
            open_catalog_app(guide_ui, GUIDE_TITLE, COLD_BOOT)
            guide_ui.wait("COUNTER APP", timeout=20)
            guide_ui.wait("Count: 0", timeout=20)

            def app_color(label):
                row_number, row = next((index, row) for index, row in enumerate(guide_ui.screen.display, 1)
                                        if label in row)
                return guide_ui.screen.buffer[row_number - 1][row.index(label)].bg

            assert app_color("COUNTER APP") == "17202c", guide_ui.text()
            guide_ui.resize(48, 18)
            guide_ui.wait("COUNTER APP", timeout=20)
            guide_ui.wait("Count: 0", timeout=20)
            guide_ui.resize(100, 30)
            guide_ui.key(b"\r")
            guide_ui.wait("Count: 1", timeout=20)
            guide_ui.wait("Saved count 1", timeout=20)

            increment_row, increment_line = next((index, row) for index, row in enumerate(guide_ui.screen.display, 1)
                                                  if "Enter Add one" in row)
            increment_x = increment_line.index("Enter Add one") + 1
            guide_ui.mouse(0, increment_x, increment_row)
            guide_ui.mouse(0, increment_x, increment_row, True)
            guide_ui.wait("Count: 2", timeout=20)
            guide_ui.wait("Saved count 2", timeout=20)

            guide_ui.open_start()
            guide_ui.choose("Settings")
            guide_ui.wait("BEE SETTINGS", timeout=20)
            guide_ui.key(b"\x1b[C")
            guide_ui.wait("Theme: Ocean", timeout=20)
            guide_ui.key(b"\x1b")
            guide_ui.wait("COUNTER APP", timeout=20)
            deadline = time.monotonic() + 20
            while app_color("COUNTER APP") != "102b39":
                assert time.monotonic() < deadline, guide_ui.text()
                guide_ui.pump(.1)

            # Workspace shutdown retains the automatic instance and its
            # acknowledged checkpoint; the next boot restores both.
            guide_ui.quit()
        finally:
            guide_ui.close()
        guide_restarted = Desktop(guide_root, project=project)
        try:
            guide_restarted.wait("COUNTER APP", timeout=COLD_BOOT)
            guide_restarted.wait("Count: 2", timeout=20)
            guide_restarted.wait("Saved: 2", timeout=20)
            # A clean return closes the view and removes its resume record,
            # so the next open starts from an empty count.
            guide_restarted.key(b"\x1b")
            guide_restarted.wait("No applications open", timeout=20)
            open_catalog_app(guide_restarted, GUIDE_TITLE, COLD_BOOT)
            guide_restarted.wait("COUNTER APP", timeout=20)
            guide_restarted.wait("Count: 0", timeout=20)
            guide_restarted.window_control("×")
            guide_restarted.wait("No applications open", timeout=20)
            guide_restarted.quit()
        finally:
            guide_restarted.close()
        evidence = deliver(project, folder)
        assert_shared_database(project)
        inspect(project, folder)

        open_source_root = folder / "open-source"
        open_source_root.mkdir()
        copy_activation(folder, open_source_root)
        open_source = run_open_probe(project, open_source_root)
        assert open_source["thread_id"] == OPEN_PROBE_THREAD, open_source
        agent_instance = open_source["window_instance"]
        agent_binding = binding_records(open_source_root, [agent_instance])
        assert set(agent_binding) == {agent_instance}, agent_binding
        agent_binding = agent_binding[agent_instance]
        expected_actor = f"bee.application:{open_source['workspace_id']}:{agent_instance}"
        assert agent_binding[0] == OPEN_PROBE_THREAD and agent_binding[1] == expected_actor, agent_binding
        assert agent_binding[2] == "active" and isinstance(agent_binding[3], int) \
            and agent_binding[3] > 0 and agent_binding[4] == 0, agent_binding
        agent_membership = thread_members(open_source_root, [expected_actor])
        assert agent_membership.get(expected_actor, (None, 0))[1] == 1, agent_membership

        removed = open_source["removed_instance"]
        surviving = open_source["surviving_instance"]
        assert removed == open_source["first_instance"] and surviving == open_source["second_instance"], open_source
        assert open_source["removed_access"] == "denied" and open_source["surviving_access"] == "active", open_source
        records = binding_records(open_source_root, [removed, surviving])
        assert set(records) == {removed, surviving}, records
        assert records[removed][2:] == ("revoked", records[removed][3], 0), records
        assert records[surviving][2] == "active" and records[surviving][4] == 0, records
        surviving_membership = records[surviving][3]
        assert isinstance(surviving_membership, int) and surviving_membership > 0, records
        actors = {instance: records[instance][1] for instance in (removed, surviving)}
        members = thread_members(open_source_root, list(actors.values()))
        assert members[actors[removed]][1] == 0 and members[actors[surviving]][1] == 1, members
        assert removed not in saved_instances(open_source_root) and surviving in saved_instances(open_source_root)

        revoke_crash_recovery(project, open_source_root, open_source,
                              folder / "open-revoke-crash")

        staged = stage_replacement(project, open_source_root)
        before_application = saved_application(open_source_root, surviving)
        before_binding = binding_records(open_source_root, [surviving])[surviving]
        before_member = thread_members(open_source_root, [before_binding[1]])[before_binding[1]]
        replacement = Desktop(open_source_root, project=project)
        try:
            replacement.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
            replacement.wait("Count: 1", timeout=20)
            replacement.wait("Access: pending", timeout=20)
            replacement.key(b"r")
            replacement.wait("Access: active", timeout=20)
            replace_v2_in_ui(replacement, staged, open_source_root)
            deadline = time.monotonic() + COLD_BOOT
            while "Agent App Updated" not in replacement.screen.display[0]:
                assert time.monotonic() < deadline, replacement.text()
                replacement.pump(.2)
            replacement.wait("AGENT APP UPDATED", timeout=COLD_BOOT)
            replacement.wait("Count: 1", timeout=20)
            replacement.wait("Stale credentials: refused", timeout=20)
            replacement.key(b"r")
            replacement.wait("Access: active", timeout=20)
            after_application = saved_application(open_source_root, surviving)
            after_binding = binding_records(open_source_root, [surviving])[surviving]
            after_member = thread_members(open_source_root, [after_binding[1]])[after_binding[1]]
            assert after_application["id"] == before_application["id"], (before_application, after_application)
            assert after_application["instance_id"] == before_application["instance_id"] == surviving
            assert after_application["thread_id"] == before_application["thread_id"] == before_binding[0]
            assert after_application["resume_schema"] == before_application["resume_schema"]
            assert json.loads(after_application["resume_state"])["count"] == 1, after_application
            assert after_binding == before_binding and after_member == before_member, \
                (before_binding, after_binding, before_member, after_member)
            replacement.key(b"d")
            replacement.wait("Access: denied", timeout=COLD_BOOT)
            wait_binding(open_source_root, [surviving],
                         lambda rows: surviving if rows.get(surviving) == ("revoked", 0) else None,
                         timeout=COLD_BOOT)
            revoked_member = thread_members(open_source_root, [before_binding[1]])[before_binding[1]]
            assert revoked_member[1] == 0 and revoked_member[0] > before_member[0], \
                (before_member, revoked_member)
            replacement.quit()
        finally:
            replacement.close()

        revoked_restart = Desktop(open_source_root, project=project)
        try:
            revoked_restart.wait("No applications open", timeout=COLD_BOOT)
            assert surviving not in saved_instances(open_source_root)
            assert binding_rows(open_source_root, [surviving]).get(surviving) == ("revoked", 0)
            # The empty desktop can paint before its startup services have
            # settled. The built-in catalog is the neutral ready boundary;
            # the revoked application must remain absent from it.
            revoked_restart.open_start()
            assert TITLE not in revoked_restart.text(), revoked_restart.text()
            revoked_restart.key(b"\x1b")
            revoked_restart.pump(.5)
            revoked_restart.quit()
        finally:
            revoked_restart.close()

        # No application is opened from the command line: the approved
        # definition has to be selectable from the desktop's own catalog.
        ui = Desktop(folder, project=project)
        try:
            ui.wait("No applications open", timeout=COLD_BOOT)
            open_admitted(ui, COLD_BOOT)
            ui.wait("APP JOURNEY DELIVERED")
            ui.wait("Saved: 0")
            ui.key(b"x")
            ui.wait("Saved: 1")
            ui.quit()
        finally:
            ui.close()

        restarted = Desktop(folder, project=project)
        try:
            restarted.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
            restarted.wait("Count: 1")
            restarted.open_start()
            assert TITLE in restarted.text(), restarted.text()
            restarted.key(b"\x1b")
            restarted.pump(.5)
            restarted.quit()
        finally:
            restarted.close()
        assert_shared_database(project)

        packed_root = folder / "packed"
        packed_root.mkdir()
        deployment = pack_deployment(project, folder / "deployment")
        packed_initial = Desktop(packed_root, packed=True, project=project, deployment=deployment)
        try:
            packed_initial.wait("No applications open", timeout=COLD_BOOT)
            packed_initial.quit()
        finally:
            packed_initial.close()
        # Packed entries have a different composed base (embedded assets).
        # Review that exact base rather than replaying a source-base approval.
        deliver(project, packed_root, deployment)
        assert_shared_database(packed_root)
        open_packed = run_open_probe(project, packed_root, packed=True,
                                     deployment=deployment)
        for field in ("unapproved_refused", "agent_exited", "direct_sender_refused"):
            assert open_source[field] == open_packed[field], (field, open_source, open_packed)
    print("App journey guide: the MCP guide example authored as "
          + guide_evidence["definition_id"] + " reached a ready preflight as plan "
          + guide_evidence["plan_digest"][:12])
    print("App journey: authored and frozen as " + evidence["artifact_digest"][:12]
          + ", staged as plan " + evidence["plan_digest"][:12]
          + " with a ready preflight, approved on proposal " + evidence["proposal_digest"][:12]
          + " with the second consume refused, applied on the reviewed composed base, admitted, "
            "opened from the desktop catalog and restored with its state after a host restart")
    print("Application open: source and packed managed agents received one approved runtime trait, "
          "opened two distinct bound applications, proved both thread facades, and exited while "
          "the applications remained live")


if __name__ == "__main__":
    exercise()

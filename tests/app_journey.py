"""Carry one authored application to an open window that survives a restart.

An application definition is authored into a governed workspace, frozen with
its digest, published, discovered, staged, preflighted, reviewed, selected,
approved, consumed and applied by the registry owner through the production
governance chain (bee.governance:workspace_call, publication_call,
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
from workspace import (ROOT, RUNTIME, configure_managed_gateway,
                       database_environment)  # noqa: E402

DEFINITION_ID = "bee.app_journey_demo:app"
TITLE = "App Journey"
# The cold first boot of a full composition, the budget the sibling desktop
# acceptances (tests/inbox_decide.py) already use for one.
COLD_BOOT = 30
OVERLAY_WRITE = "registry.overlay.apply"
OVERLAY_OWNER = "bee.app_journey_probe:activation_overlay"
OPEN_SEED = "bee.app_open_probe:seed"
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
                                  "policies": ["bee:ordinary_app_subsystem_boundary"],
                                  "thread_access": "observe_post"})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def assert_overlay_authority(project):
    """Overlays belong to the destination owner: nothing else may write one."""
    granted, denied = set(), set()
    for index in (project / "src").rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        for entry in document.get("entries", []):
            policy = entry.get("policy")
            if not isinstance(policy, dict) or OVERLAY_WRITE not in (policy.get("actions") or []):
                continue
            identity = f'{document["namespace"]}:{entry["name"]}'
            (granted if policy.get("effect") == "allow" else denied).add(identity)
    assert granted == {"bee:governance_destination_service_policy"}, granted
    assert denied == {"bee:app_boundary_policy", "bee:scope_managing_app_boundary"}, denied


def assert_delivery_has_no_overlay_authority(project):
    """The agent's delivery and publish surfaces reach publication and
    destination staging; they grant no overlay write, which is the activation
    owner's alone."""
    wanted = {"bee:gateway_tool_delivery_policy", "bee:gateway_tool_publish_policy",
              "bee:delivery_facade_policy"}
    seen = set()
    for index in (project / "src").rglob("_index.yaml"):
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


def deliver(project, folder, pack_file=None):
    args = [str(RUNTIME), "run"]
    if pack_file:
        args.append(str(pack_file))
    args += ["--verbose", "app-journey-deliver", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=folder if pack_file else project, capture_output=True, text=True,
                            timeout=300, env=database_environment(folder))
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
        "not allowed to apply registry overlay: bee.app_journey_probe:forbidden_overlay", evidence
    return evidence


def guide(project, folder):
    """The guide's own example, authored through the real chain, must reach a
    ready preflight. This is what keeps the product guide from rotting: the
    same value an agent reads over MCP is published and staged here."""
    args = [str(RUNTIME), "run", "--verbose", "app-journey-guide", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(folder))
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    match = re.search(r"APP_JOURNEY_GUIDE\s+(\{.*\})", output)
    assert match, output
    evidence = json.loads(match.group(1))
    for name in ("snapshot_digest", "artifact_digest", "plan_digest"):
        assert re.fullmatch(r"[0-9a-f]{64}", evidence[name]), (name, evidence)
    assert evidence["ready"] is True and evidence["example_matches"] is True, evidence
    assert evidence["definition_id"] == "bee.guide_demo:app", evidence
    return evidence


def inspect(project, folder):
    """A separate boot must compose the reviewed definition and admit it."""
    args = [str(RUNTIME), "run", "--verbose", "app-journey-inspect", "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=300, env=database_environment(folder))
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
        "policies": ["bee.app_open_probe:view_policy", "bee.app_open_probe:host_lookup_policy",
                      "bee.app_open_probe:evidence_policy", "bee.app_open_probe:operator_signal_policy"]})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def configure_open_agent(project):
    """Bind the scripted executable at the fixture edge; the managed carrier
    still owns gateway admission, materialization and revocation."""
    index = project / "src/open_probe/_index.yaml"
    document = yaml.safe_load(index.read_text())
    policy = next(entry for entry in document["entries"] if entry["name"] == "managed_agent_policy")
    policy["data"]["executables"] = {"claude": str(ROOT / "tests/fixtures/harness/bin/claude")}
    policy["data"]["environment"]["BEE_FIXTURE_STREAM"] = \
        str(ROOT / "tests/fixtures/drivers/claude/stream-json-2/plain.jsonl")
    index.write_text(yaml.safe_dump(document, sort_keys=False))

    approvals = project / "src/approvals/_index.yaml"
    approval_document = yaml.safe_load(approvals.read_text())
    approvers = next(entry for entry in approval_document["entries"]
                     if entry["name"] == "approver_policies")
    approvers["policies"].append({"name": "app-open-runtime",
                                  "approvers": ["bee.app_open.operator"],
                                  "max_ttl_ms": 60000})
    approvals.write_text(yaml.safe_dump(approval_document, sort_keys=False))


def run_open_probe(project, directory, packed=False, pack_file=None):
    """Call application_open over the real loopback MCP endpoint."""
    Path(directory).mkdir(parents=True, exist_ok=True)
    report_path = (Path(directory) if packed else project) / "evidence/open.json"
    report_path.unlink(missing_ok=True)
    ui = Desktop(directory, packed=packed, project=project, pack_file=pack_file)
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
            while "APP JOURNEY DELIVERED" not in ui.text() or progress.get("passed") is not True:
                ui.pump()
                if report_path.exists():
                    try:
                        progress = json.loads(report_path.read_text())
                    except json.JSONDecodeError:
                        progress = {}
                    assert progress.get("passed") is not False, progress
                if time.monotonic() >= deadline or ui.process.poll() is not None:
                    ui.wait("APP JOURNEY DELIVERED", timeout=0)
                    raise AssertionError(f"open probe did not complete: {progress}")
            ui.wait("Saved: 0")
            ui.key(b"x")
            ui.wait("Saved: 1")
        except AssertionError as problem:
            evidence = report_path
            detail = evidence.read_text() if evidence.exists() else "missing"
            raise AssertionError(f"{problem}; open evidence={detail}") from problem
        # This first desktop owns the managed runner whose declared output
        # drain is 2s plus a 1s runner drain. Prove that bounded cleanup rather
        # than applying the ordinary sub-second desktop-only shutdown budget.
        started = time.monotonic()
        os.write(ui.master, b"\x11")
        while ui.process.poll() is None and time.monotonic() - started < 4:
            ui.pump(.02)
        assert ui.process.poll() == 0, ui.text()
        assert time.monotonic() - started < 4
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
    assert report["direct_sender_refused"] is True, report
    restarted = Desktop(directory, packed=packed, project=project, pack_file=pack_file)
    try:
        restarted.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
        restarted.wait("Count: 1")
        restarted.wait("Saved: 1")
        restarted.quit()
    finally:
        restarted.close()
    return report


def copy_activation(source, destination):
    """Clone approved durable state; boot recovery must reapply its overlay."""
    for name in ("registry", "governance", "approvals"):
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
    with sqlite3.connect(Path(root) / "workspace.db") as db:
        row = db.execute("SELECT value FROM workspace_state WHERE singleton = 1").fetchone()
    assert row, "workspace checkpoint is missing"
    return {item["instance_id"] for item in json.loads(row[0])["applications"]}


def revoke_crash_recovery(project, source_root, report, destination):
    """Crash after the durable revoke fence and before Threads leave.

    The pause exists only in this disposable source copy. Production receives
    no test switch or timing branch.
    """
    shutil.copytree(source_root, destination)
    host = project / "src/core/host/main.lua"
    original = host.read_text()
    anchor = "            value, operation_error = database.thread_bindings:begin_revoke(request.value)\n"
    assert original.count(anchor) == 1
    host.write_text(original.replace(
        anchor,
        anchor + "            if value and not operation_error then while true do time.sleep(\"1s\") end end\n"))
    instance_ids = [report["first_instance"], report["second_instance"]]
    ui = Desktop(destination, project=project)
    try:
        ui.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
        assert all(value == ("active", 0) for value in binding_rows(destination, instance_ids).values())
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
        restarted.wait("APP JOURNEY DELIVERED", timeout=COLD_BOOT)
        wait_binding(destination, instance_ids,
                     lambda rows: revoked if rows.get(revoked) == ("revoked", 0) else None)
        assert revoked not in saved_instances(destination)
        restarted.quit()
    finally:
        restarted.close()


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-app-journey-") as directory, \
            patch.dict(os.environ, {"WIPPY_NODE_ID": Path(directory).name}):
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/app_journey", project / "src/probe")
        shutil.copytree(ROOT / "tests/fixtures/app_open", project / "src/open_probe")
        open_manifest = yaml.safe_load((project / "src/open_probe/_index.yaml").read_text())
        open_seed = next(entry for entry in open_manifest["entries"] if entry["name"] == "seed")
        assert open_seed["imports"]["client"] == "bee.application:client"
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        bind_admission(project)
        add_open_admission(project)
        configure_open_agent(project)
        shutil.copytree(ROOT / "tests/modules/gateway/src/managed", project / "src/managed")
        configure_managed_gateway(project)
        assert_overlay_authority(project)
        assert_delivery_has_no_overlay_authority(project)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                        "--set", "lua.type_system.strict=true"], cwd=project, check=True, timeout=300)
        guide_evidence = guide(project, folder)
        evidence = deliver(project, folder)
        assert_shared_database(project)
        inspect(project, folder)

        open_source_root = folder / "open-source"
        open_source_root.mkdir()
        copy_activation(folder, open_source_root)
        open_source = run_open_probe(project, open_source_root)

        revoke_crash_recovery(project, open_source_root, open_source,
                              folder / "open-revoke-crash")

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
        (packed_root / ".wippy").mkdir()
        shutil.copy2(project / ".wippy.yaml", packed_root / ".wippy.yaml")
        pack_file = packed_root / "bee.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack_file)], cwd=project,
                       check=True, timeout=300)
        # Packed entries have a different composed base (embedded assets).
        # Review that exact base rather than replaying a source-base approval.
        deliver(project, packed_root, pack_file)
        assert_shared_database(packed_root)
        open_packed = run_open_probe(project, packed_root, packed=True,
                                     pack_file=pack_file)
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

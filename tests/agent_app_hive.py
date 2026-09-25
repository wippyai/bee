"""Carry the retained Agent App v2 artifact across Hive into a normal desktop.

This is intentionally opt-in and consumes no provider inference. The optional
``BEE_AGENT_APP_HIVE_ARTIFACT`` input is retained evidence from a prior managed
agent run. Its source fixture recreates exactly the v2 artifact from its
entries; the destination has only its digest until production publication and
Hive deliver the bytes.
"""
import json
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, classic_workspace, workspace_checkpoint  # noqa: E402

TITLE = "Agent App"
MARKER = "AGENT APP UPDATED"
DEFINITION_ID = "bee.agent_app_demo:app"
DEFAULT_ARTIFACT = ROOT / ".wippy/evidence/agent-app-20260919-225922/authored.json"


def evidence_root():
    selected = os.environ.get("BEE_AGENT_APP_HIVE_EVIDENCE")
    root = Path(selected).resolve() if selected else ROOT / ".wippy/evidence" / time.strftime("agent-app-hive-%Y%m%d-%H%M%S")
    root.mkdir(parents=True, exist_ok=bool(selected))
    return root


def capture(folder, name, desktop):
    ui = folder / "ui"
    ui.mkdir(exist_ok=True)
    path = ui / (name + ".txt")
    path.write_text(desktop.text() + "\n")
    return str(path.relative_to(folder))


def runtime_identity():
    digest = hashlib.sha256()
    with RUNTIME.open("rb") as runtime:
        for chunk in iter(lambda: runtime.read(1024 * 1024), b""):
            digest.update(chunk)
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                              text=True, check=True).stdout.strip()
    return {"path": str(RUNTIME), "sha256": digest.hexdigest(), "source_revision": revision}


def retained_artifact():
    path = Path(os.environ.get("BEE_AGENT_APP_HIVE_ARTIFACT", DEFAULT_ARTIFACT)).resolve()
    document = json.loads(path.read_text())
    updated = document.get("updated")
    entries = document.get("entries")
    assert isinstance(updated, dict), "retained artifact has no updated entry"
    assert re.fullmatch(r"[0-9a-f]{64}", updated.get("artifact_digest", "")), updated
    assert isinstance(entries, list) and len(entries) == 1, "only the retained v2 application entry is accepted"
    entry = entries[0]
    application = entry.get("meta", {}).get("application", {})
    assert entry.get("id") == DEFINITION_ID and entry.get("kind") == "process.lua", entry
    expected_revision = "1" if os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_PROJECT") else "2"
    assert application.get("title") == TITLE and application.get("revision") == expected_revision, application
    return path, updated["artifact_digest"]


def application_identity(folder):
    applications = workspace_checkpoint(folder / "workspace.db")["applications"]
    matches = [item for item in applications if item["definition_id"] == DEFINITION_ID]
    assert len(matches) == 1, matches
    return matches[0]["id"], matches[0]["instance_id"]


def configure_destination(project, workspace_id=None, source_node="node-1"):
    """Install the destination's local policy in its source composition."""
    if workspace_id is not None:
        governance_path = project / "modules/gov/src/_index.yaml"
        governance = yaml.safe_load(governance_path.read_text())
        profiles = next(item for item in governance["entries"] if item["name"] == "activation_profiles")
        profiles["data"] = {"profiles": [{
            "workspace_id": workspace_id, "source_node": source_node,
            "source_workspace": "agent-app-source", "component": "bee.agent_app_demo/app",
            "resolver": "overlay", "overlay_owner": "bee.replica_probe:activation_overlay",
            "approval_policy": "local-agent-app-hive", "parameters": [],
            "allow": {"packages": ["bee.agent_app_demo/app"], "namespaces": ["bee.agent_app_demo"],
                      "kinds": ["process.lua"], "databases": [], "grants": [],
                      "modules": ["tty", "process", "channel", "json"]},
        }]}
        governance_path.write_text(yaml.safe_dump(governance, sort_keys=False))

        approvals_path = project / "src/_index.yaml"
        approvals = yaml.safe_load(approvals_path.read_text())
        policies = next(item for item in approvals["entries"] if item["name"] == "approver_policies")
        policies["policies"] = [{"name": "local-agent-app-hive", "approvers": ["bee.replica_probe"],
                                 "max_ttl_ms": 60000}]
        approvals_path.write_text(yaml.safe_dump(approvals, sort_keys=False))

    security_path = project / "src/security/_index.yaml"
    security = yaml.safe_load(security_path.read_text())
    admission = next(item for item in security["entries"] if item["name"] == "application_admission")
    if not any(item["definition_id"] == DEFINITION_ID for item in admission["bindings"]):
        admission["bindings"].append({"definition_id": DEFINITION_ID,
                                      "policies": ["bee.security:ordinary_app_subsystem_boundary"]})
    security_path.write_text(yaml.safe_dump(security, sort_keys=False))


def prepare_destination(destination, evidence, source_node="node-1"):
    shutil.copytree(ROOT / "src", destination / "src")
    shutil.copytree(ROOT / "modules", destination / "modules")
    for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
        shutil.copy2(ROOT / name, destination / name)
    # This acceptance invokes the assembled runtime directly rather than
    # through the native launcher. Supply the same host-owned bindings on every
    # boot so the registry history created by the headless Hive composition is
    # valid when the normal desktop composition resumes it.
    for name in ("self", "agy", "claude", "codex", "grok"):
        os.environ[name] = str(RUNTIME)
    os.environ["home"] = str(destination)
    os.environ.setdefault("ANTHROPIC_API_KEY", "fixture-only")
    desktop = Desktop(destination, project=destination)
    try:
        desktop.wait("No applications open", timeout=30)
        capture(evidence, "pre-established-destination", desktop)
        desktop.quit()
    finally:
        desktop.close()
    workspace_id = classic_workspace(destination / "workspace.db")
    configure_destination(destination, workspace_id, source_node)
    return workspace_id


def bridge(destination, workspace_id, artifact, evidence):
    environment = os.environ.copy()
    environment.update({
        "BEE_HIVE_SUPERVISOR_RUNTIME": str(RUNTIME),
        "BEE_AGENT_APP_HIVE_ARTIFACT": str(artifact),
        "BEE_AGENT_APP_HIVE_DESTINATION": str(destination),
        "BEE_AGENT_APP_HIVE_WORKSPACE": workspace_id,
        "GOWORK": "off",
        "GOTOOLCHAIN": "go1.27.0",
    })
    source_project = os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_PROJECT")
    source_state = os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_STATE")
    source_workspace = os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_WORKSPACE")
    if source_project or source_state or source_workspace:
        assert source_project and source_state and source_workspace, "continuous source needs project, state and workspace"
        environment.update({"BEE_AGENT_APP_HIVE_SOURCE_PROJECT": source_project,
                            "BEE_AGENT_APP_HIVE_SOURCE_STATE": source_state,
                            "BEE_AGENT_APP_HIVE_SOURCE_WORKSPACE": source_workspace})
    command = ["go", "test", "-race", "-count=1", "-v", "tests/hive_remote.go",
               "tests/hive_supervisor_test.go", "tests/hive_replica_test.go",
               "-run", "^TestHiveSupervisorAgentSource$" if source_project else "^TestHiveSupervisorAgentArtifact$"]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=360, env=environment)
    output = result.stdout + result.stderr
    (evidence / "hive-bridge.log").write_text(output)
    assert result.returncode == 0, output[-12000:]
    for marker in ("agent_artifact_absent", "agent_artifact_published", "agent_artifact_available",
                   "agent_artifact_staged", "agent_artifact_applied"):
        assert marker in output, output[-12000:]
    # The Go acceptance synchronously waits for `stop` on both coordinators;
    # only after this return can the ordinary desktop boot below own its host.
    expected = ("locally applied Agent App was published by its authoring source"
                if source_project else "retained Agent App v2 was recreated only on the source")
    assert expected in output, output[-12000:]


def tree_digest(root):
    """Measure the retained source composition without interpreting it."""
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def open_and_restart(destination, workspace_id, evidence, marker=MARKER):
    desktop = Desktop(destination, project=destination)
    try:
        desktop.wait("No applications open", timeout=30)
        deadline = time.monotonic() + 30
        while True:
            desktop.open_start()
            if TITLE in desktop.text():
                break
            desktop.key(b"\x1b")
            if time.monotonic() >= deadline:
                raise AssertionError("Agent App did not enter the recovered Start catalog\n" + desktop.text())
            desktop.pump(.2)
        capture(evidence, "start-menu-agent-app", desktop)
        desktop.choose(TITLE)
        desktop.wait(marker, timeout=30)
        desktop.wait("Count: 0", timeout=30)
        capture(evidence, "agent-app-initial", desktop)
        desktop.key(b"\x1b\t")
        desktop.key(b"x")
        desktop.wait("Count: 1", timeout=30)
        desktop.wait("Saved: 1", timeout=30)
        capture(evidence, "agent-app-saved", desktop)
        first_identity = application_identity(destination)
        desktop.quit()
    finally:
        desktop.close()

    assert classic_workspace(destination / "workspace.db") == workspace_id, "desktop restart changed destination workspace identity"
    restarted = Desktop(destination, project=destination)
    try:
        restarted.wait(marker, timeout=30)
        restarted.wait("Count: 1", timeout=30)
        capture(evidence, "agent-app-cold-restart", restarted)
        restarted_identity = application_identity(destination)
        assert restarted_identity == first_identity, "cold restart replaced Agent App logical identity"
        restarted.quit()
    finally:
        restarted.close()
    return first_identity, restarted_identity


def exercise():
    artifact, digest = retained_artifact()
    authored = json.loads(artifact.read_text())
    source_project = os.environ.get("BEE_AGENT_APP_HIVE_SOURCE_PROJECT")
    source_node = authored.get("source_node", "node-1") if source_project else "node-1"
    source_workspace_id = authored.get("workspace_id")
    marker = authored.get("application_marker", MARKER)
    if source_project:
        assert source_node == "node-1", "continuous source must retain its pre-authoring Hive identity"
        assert re.fullmatch(r"[0-9a-f]{32}", source_workspace_id or ""), source_workspace_id
        os.environ["BEE_AGENT_APP_HIVE_SOURCE_WORKSPACE"] = source_workspace_id
    source_tree_before = tree_digest(Path(source_project) / "src") if source_project else None
    evidence = evidence_root()
    shutil.copy2(artifact, evidence / "authored.json")
    destination = evidence / "destination"
    receipt = {"schema": 1, "status": "running", "authored_artifact": {"path": "authored.json",
               "source_evidence_path": str(artifact),
               "updated_artifact_digest": digest}, "runtime": runtime_identity(), "timings_seconds": {}}
    started = time.monotonic()
    try:
        workspace_id = prepare_destination(destination, evidence, source_node)
        receipt["timings_seconds"]["pre_establish_destination"] = round(time.monotonic() - started, 3)
        bridge_started = time.monotonic()
        bridge(destination, workspace_id, artifact, evidence)
        source_tree_after = tree_digest(Path(source_project) / "src") if source_project else None
        assert source_tree_after == source_tree_before, "Hive bridge changed the approved source composition"
        receipt["timings_seconds"]["hive_bridge"] = round(time.monotonic() - bridge_started, 3)
        desktop_started = time.monotonic()
        first_identity, restarted_identity = open_and_restart(destination, workspace_id, evidence, marker)
        receipt["timings_seconds"]["desktop_open_and_cold_restart"] = round(time.monotonic() - desktop_started, 3)
        receipt["destination_workspace_id"] = workspace_id
        receipt["source"] = {"mode": "continuous_authoring_state" if source_project else "retained_artifact_fixture",
                             "node_id": source_node, "workspace_id": source_workspace_id,
                             "project": source_project, "src_sha256": source_tree_after}
        receipt["logical_identity"] = {
            "before_restart": {"view_id": first_identity[0], "instance_id": first_identity[1]},
            "after_restart": {"view_id": restarted_identity[0], "instance_id": restarted_identity[1]},
        }
        receipt["status"] = "passed"
    except BaseException as error:
        receipt["status"] = "failed"
        receipt["error"] = repr(error)
        raise
    finally:
        receipt["timings_seconds"]["total"] = round(time.monotonic() - started, 3)
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    subject = "authored artifact " if source_project else "retained v2 artifact "
    print("Agent App Hive: " + subject + digest[:12]
          + " crossed Hive, was destination-reviewed and approved, then opened and cold-restored in the same desktop; evidence in "
          + str(evidence))


if __name__ == "__main__":
    exercise()

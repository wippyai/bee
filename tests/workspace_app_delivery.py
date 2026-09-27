"""An agent builds an application to a written spec on an unmodified install.

The composition is the shipped one: its Governance publication and activation
profiles and its approver policies are compared byte for byte with the source
tree, and nothing configures a profile. A managed agent, launched through the
production launch definition, admission, carrier, placement and gateway with
the spec (tests/fixtures/workspace_app_delivery/SPEC.md) as its brief, authors
the application using only its gateway tools: the overlay guide, its own
overlay, freeze and a delivery request that names no workspace. The application
requests threads.read, threads.message, workspace.files.read, app.database and
agents.launch; the person then reviews the plan in Overlays and approves it in
Approvals, the activation owner applies it with its host-created volume and
isolated database, and the application opens from the Start menu and behaves as
the spec says, including its saved count and its database rows after a restart.
The installed app launches the shipped Claude batch definition, waits for the
placed child to settle, reads its result and steers it once.

The far end of the launch is the scripted protocol agent
(tests/fixtures/harness/gateway_client.go, mode spec): it writes the answer a
model would write, tests/fixtures/workspace_app_delivery/tally.lua, so the
proof needs no provider account. BEE_WORKSPACE_APP_PROVIDER=claude runs the
installed Claude Code at that end instead; it reads the spec and the guide and
writes the application itself, consuming inference. BEE_RUNTIME names the
runtime used to compose and author the fixture. BEE_WORKSPACE_APP_EVIDENCE
overrides the retained evidence directory.
"""
import errno
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_journey import apply_staged_in_ui, open_catalog_app  # noqa: E402
from tui_smoke import Desktop  # noqa: E402
from workspace import (ROOT, RUNTIME, classic_workspace, database_environment, name_node,  # noqa: E402
                       stage_hive_source)

FIXTURE = ROOT / "tests/fixtures/workspace_app_delivery"
COLD_BOOT = 30
SOURCE = "tally"
VERSION = "1.0.0"
TITLE = "Tally"
DEFINITION_ID = "app.tally:app"
APPROVAL_POLICY = "workspace-application-delivery"
SHIPPED = ["modules/gov/src/_index.yaml", "src/_index.yaml", "src/deps/_index.yaml", "src/env/_index.yaml"]
PROVIDER = os.environ.get("BEE_WORKSPACE_APP_PROVIDER", "scripted")
HIVE_SOURCE = os.environ.get("BEE_WORKSPACE_APP_HIVE_SOURCE_NODE")
NATIVE_OWNER = os.environ.get("BEE_WORKSPACE_APP_NATIVE_OWNER") == "1"
DESKTOP_RUNTIME = Path(os.environ.get("BEE_WORKSPACE_APP_DESKTOP_RUNTIME", RUNTIME)).resolve()
NATIVE_DESKTOP = os.environ.get("BEE_WORKSPACE_APP_NATIVE_DESKTOP") == "1"
# A live agent is told only how to use its tools; the spec is the person's.
LIVE_BRIEF = ("Use only the Bee MCP tools; never a shell, a file tool or another agent. Read the overlay tool's "
              "guide operation first and follow it. Author the application below in your own overlay, freeze it, "
              "then call the delivery tool with operation request, version 1.0.0 and the frozen snapshot_digest. "
              "If delivery names a diagnostic, repair it, freeze again and request delivery with version 1.0.1, "
              "1.0.2 and so on. Stop when delivery reports ready.\n\n")


GREETING = "hello tally"
SHARED_SUBPATH = "shared"
DATABASE_NAME = "tally"
CHILD_DEFINITION = "bee.driver.claude:research_batch"


def grant_identities(workspace_id):
    """The host-installed volume and database identities for one workspace."""
    owner = f"bee.gov.apps:{workspace_id}.tally"
    # The classic folder workspace is rooted at the node's workspace root.
    volume = ("bee.gov.grants:volume."
              + hashlib.sha256(f"{owner}\nbee.env:workspace_root\n{SHARED_SUBPATH}".encode()).hexdigest())
    database = ("bee.gov.grants:database."
                + hashlib.sha256(f"{owner}\n{DATABASE_NAME}".encode()).hexdigest())
    return volume, database


def application_database(folder, project):
    workspace_id = classic_workspace(folder / "workspace.db")
    _, database_id = grant_identities(workspace_id)
    suffix = database_id.rsplit(".", 1)[-1]
    return project / ".wippy" / "app-db" / f"{suffix}.db"


def wait_for_agent_run(folder, project, desktop, timeout=60):
    app_db = application_database(folder, project)
    deadline = time.monotonic() + timeout
    runs = []
    while time.monotonic() < deadline:
        desktop.pump(.1)
        if app_db.exists():
            with sqlite3.connect(f"file:{app_db}?mode=ro", uri=True) as db:
                try:
                    runs = db.execute(
                        "SELECT attempt_id, definition_ref, state, outcome, steer FROM tally_runs"
                    ).fetchall()
                except sqlite3.OperationalError as exc:
                    if "no such table" not in str(exc):
                        raise
            if any(state == "ended" and outcome == "succeeded" and steer == "sent"
                   for _, _, state, outcome, steer in runs):
                return
    raise AssertionError(f"the installed app did not record a settled child run: {runs}\n{desktop.text()}")


def answer_entries():
    """The entries.json a model writes for SPEC.md."""
    source = (FIXTURE / "tally.lua").read_text()
    return [{"id": DEFINITION_ID, "kind": "process.lua",
             "data": {"source": source, "method": "main",
                      "modules": ["tty", "process", "channel", "json", "funcs", "fs", "sql", "hash"],
                      "imports": {"client": "bee.application:client", "appearance": "bee.application:appearance",
                                  "frame": "bee.application:frame", "agents": "bee.application:agents",
                                  "canonical": "bee.threads.records:canonical"}},
             "meta": {"type": "bee.application", "application": {
                 "api_version": 1, "lifetime": "view", "revision": "1", "title": TITLE,
                 "instance_policy": "singleton", "resume_schema": "tally.v1", "restart_policy": "automatic"}}},
            {"id": "app.tally:threads_read", "kind": "ns.requirement",
             "meta": {"value_kind": "security.policy", "capability": "threads.read",
                      "parameters": {"scope": "owned"}, "reason": "Read threads owned by this application"},
             "data": {"targets": [{"entry": DEFINITION_ID, "path": ".security.policies +="}]}},
            {"id": "app.tally:shared_files", "kind": "ns.requirement",
             "meta": {"value_kind": "security.policy", "capability": "workspace.files.read",
                      "parameters": {"subpath": SHARED_SUBPATH}, "reason": "Read the shared workspace greeting"},
             "data": {"targets": [{"entry": DEFINITION_ID, "path": ".security.policies +="}]}},
            {"id": "app.tally:tally_db", "kind": "ns.requirement",
             "meta": {"value_kind": "security.policy", "capability": "app.database",
                      "parameters": {"name": DATABASE_NAME}, "reason": "Persist tally rows across restart"},
             "data": {"targets": [{"entry": DEFINITION_ID, "path": ".security.policies +="}]}},
            {"id": "app.tally:agent_launch", "kind": "ns.requirement",
             "meta": {"value_kind": "security.policy", "capability": "agents.launch",
                      "parameters": {"definitions": [CHILD_DEFINITION]},
                      "reason": "Launch the allow-listed workspace summarizer"},
             "data": {"targets": [{"entry": DEFINITION_ID, "path": ".security.policies +="}]}},
            {"id": "app.tally:child_message", "kind": "ns.requirement",
             "meta": {"value_kind": "security.policy", "capability": "threads.message",
                      "parameters": {"scope": "children"},
                      "reason": "Steer the child it launched"},
             "data": {"targets": [{"entry": DEFINITION_ID, "path": ".security.policies +="}]}}]


def compose(folder):
    project = folder / "project"
    shutil.copytree(ROOT / "src", project / "src")
    shutil.copytree(ROOT / "modules", project / "modules")
    for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
        shutil.copy2(ROOT / name, project / name)
    (project / SHARED_SUBPATH).mkdir(parents=True, exist_ok=True)
    (project / SHARED_SUBPATH / "greeting.txt").write_text(GREETING)
    shutil.copytree(FIXTURE, project / "src/workspace_app_probe")
    for relative in SHIPPED:
        assert (project / relative).read_bytes() == (ROOT / relative).read_bytes(), relative
    # A Hive acceptance later starts this project as its named source node.
    if HIVE_SOURCE:
        name_node(project, HIVE_SOURCE)
        stage_hive_source(project)
    elif NATIVE_OWNER:
        # A standalone owner derives its relay identity from the native state
        # directory. Keep authoring and the desktop client on that same node.
        native_state = (folder / "native-state").resolve()
        owner_node = "bee-owner-" + hashlib.sha256(str(native_state).encode()).hexdigest()[:16]
        name_node(project, owner_node)
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


def configure_driver_fixture(folder):
    """Resolve the shipped Claude policy to a fixture that emits captured output."""
    shim_dir = folder / "driver-bin"
    shim_dir.mkdir()
    shim = shim_dir / "claude"
    fixture = ROOT / "tests/fixtures/harness/bin/claude"
    stream = ROOT / "tests/fixtures/drivers/claude/stream-json-2/plain.jsonl"
    shim.write_text("#!/bin/sh\nexport BEE_FIXTURE_STREAM=" + shlex.quote(str(stream)) +
                    "\nexec " + shlex.quote(str(fixture)) + " \"$@\"\n")
    shim.chmod(0o755)
    os.environ["PATH"] = str(shim_dir) + os.pathsep + os.environ.get("PATH", "")


def author(project, folder):
    """The managed agent's attempt, started by the host with the spec as brief."""
    workspace_id = classic_workspace(folder / "workspace.db")
    spec = (FIXTURE / "SPEC.md").read_text()
    if PROVIDER == "claude":
        brief = LIVE_BRIEF + spec
    else:
        brief = spec
    author_environment = database_environment(folder, BEE_WORKSPACE_APP_WORKSPACE=workspace_id,
                                               BEE_WORKSPACE_APP_BRIEF=brief)
    if PROVIDER == "scripted":
        author_environment.update(BEE_CLAUDE_BIN=str(ROOT / "tests/fixtures/harness/bin/claude"),
                                 claude=str(ROOT / "tests/fixtures/harness/bin/claude"),
                                 ANTHROPIC_API_KEY="")
    result = subprocess.run([str(RUNTIME), "run", "--verbose", "workspace-app-author",
                             "--set", f"registry.history_path={folder}/registry.db"],
                            cwd=project, capture_output=True, text=True, timeout=1500,
                            env=author_environment)
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


def occupy_gossip_port(state_dir):
    """Keep the saved gossip port busy while the native owner restarts."""
    path = Path(state_dir) / "hive" / "gossip.port"
    assert path.is_file(), path
    port = int(path.read_text().strip())
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        listener.bind(("0.0.0.0", port))
    except OSError as exc:
        listener.close()
        assert exc.errno == errno.EADDRINUSE, f"cannot reserve saved gossip port {port}: {exc}"
        return port, None
    return port, listener


def exercise():
    folder = evidence_root()
    print("Evidence:", folder)
    if PROVIDER == "scripted":
        # Resolve the shipped Claude policy's executable_env through the
        # fixture protocol binary for each node this acceptance boots.
        fixture_bin = str(ROOT / "tests/fixtures/harness/bin")
        if fixture_bin not in os.environ.get("PATH", "").split(os.pathsep):
            os.environ["PATH"] = fixture_bin + os.pathsep + os.environ.get("PATH", "")
    project = compose(folder)
    if PROVIDER == "scripted":
        configure_driver_fixture(folder)
    first = Desktop(folder, project=project, runtime=DESKTOP_RUNTIME, native=NATIVE_DESKTOP,
                    state_dir=folder / "native-state" if NATIVE_DESKTOP else None)
    try:
        first.wait("No applications open", timeout=COLD_BOOT)
        first.quit()
    finally:
        first.close()

    report = author(project, folder)
    if PROVIDER == "scripted":
        assert_authored(report)

    os.environ["BEE_WORKSPACE_APP_WORKSPACE"] = classic_workspace(folder / "workspace.db")
    if not NATIVE_DESKTOP:
        os.environ["BEE_WORKSPACE_APP_INSPECT"] = "1"
    ui = Desktop(folder, project=project, runtime=DESKTOP_RUNTIME, native=NATIVE_DESKTOP,
                 state_dir=folder / "native-state" if NATIVE_DESKTOP else None)
    try:
        ui.wait("No applications open", timeout=COLD_BOOT)
        ui.pump(.5)
        version = staged_version(folder)
        assert PROVIDER != "scripted" or version == VERSION, version
        apply_staged_in_ui(ui, {"workspace": SOURCE, "version": version, "approval_policy": APPROVAL_POLICY},
                           folder, expected_capability=["Read owned threads",
                                                        "Read workspace files under shared",
                                                        "Use an isolated application database named tally",
                                                        "Message child threads",
                                                        "Launch managed agents from " + CHILD_DEFINITION])
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
        wait_for_agent_run(folder, project, ui)
        if not NATIVE_DESKTOP:
            grant_evidence = project / "evidence/grant.json"
            deadline = time.monotonic() + 35
            while not grant_evidence.exists() and time.monotonic() < deadline:
                ui.pump(.1)
            assert grant_evidence.exists(), "installed grant scope was not verified"
            grant = json.loads(grant_evidence.read_text())
            assert grant["capabilities"] == ["agents.launch", "app.database", "threads.message", "threads.read",
                                                    "workspace.files.read"], grant
            assert len(grant["policies"]) == 6, grant
            volume_id, database_id = grant_identities(classic_workspace(folder / "workspace.db"))
            assert grant["volume_id"] == volume_id, grant
            assert grant["database_id"] == database_id, grant
        ui.window_control("×")
        ui.wait("No applications open", timeout=20)
        ui.quit()
    finally:
        ui.close()
        os.environ.pop("BEE_WORKSPACE_APP_INSPECT", None)
        os.environ.pop("BEE_WORKSPACE_APP_WORKSPACE", None)

    held_gossip_port = None
    saved_gossip_port = None
    if NATIVE_DESKTOP:
        stopped = subprocess.run([str(DESKTOP_RUNTIME), "--state", str(folder / "native-state"), "stop"],
                                 cwd=project, env=database_environment(folder), capture_output=True,
                                 text=True, timeout=90)
        stop_output = stopped.stdout + stopped.stderr
        assert stopped.returncode == 0 and "Bee stopped" in stop_output, stop_output
        saved_gossip_port, held_gossip_port = occupy_gossip_port(folder / "native-state")

    # The source-runtime fixture exits its owner with the terminal process;
    # native mode keeps the owner alive and needs the explicit stop above.
    restarted = Desktop(folder, project=project, runtime=DESKTOP_RUNTIME, native=NATIVE_DESKTOP,
                        state_dir=folder / "native-state" if NATIVE_DESKTOP else None)
    try:
        restarted.wait("No applications open", timeout=COLD_BOOT)
        deadline = time.monotonic() + COLD_BOOT
        while True:
            restarted.open_start()
            if TITLE in restarted.text():
                restarted.choose(TITLE)
                break
            restarted.key(b"\x1b")
            assert time.monotonic() < deadline, restarted.text()
            restarted.pump(.1)
        if NATIVE_DESKTOP:
            gossip_port = int((folder / "native-state" / "hive" / "gossip.port").read_text().strip())
            assert gossip_port != saved_gossip_port, (gossip_port, saved_gossip_port)
        restarted.wait("TALLY", timeout=COLD_BOOT)
        restarted.quit()
    finally:
        restarted.close()
        if NATIVE_DESKTOP:
            stopped = subprocess.run([str(DESKTOP_RUNTIME), "--state", str(folder / "native-state"), "stop"],
                                     cwd=project, env=database_environment(folder), capture_output=True,
                                     text=True, timeout=90)
            stop_output = stopped.stdout + stopped.stderr
            assert stopped.returncode == 0 and "Bee stopped" in stop_output, stop_output
        if held_gossip_port is not None:
            held_gossip_port.close()
    workspace_id = classic_workspace(folder / "workspace.db")
    app_db = application_database(folder, project)
    with sqlite3.connect(f"file:{app_db}?mode=ro", uri=True) as db:
        rows = db.execute("SELECT n, note FROM tally_rows ORDER BY rowid").fetchall()
        runs = db.execute("SELECT attempt_id, definition_ref, state, outcome, steer FROM tally_runs ORDER BY rowid").fetchall()
    assert rows == [(1, GREETING), (2, GREETING), (3, GREETING)], rows
    # The installed app launched the shipped Claude batch definition under its
    # generated agents.launch grant, waited for the placed child to
    # settle, read its result and steered it once under threads.message.
    assert runs, "the installed app recorded no agent launch"
    for attempt_id, definition_ref, state, outcome, steer in runs:
        assert definition_ref == CHILD_DEFINITION, runs
        assert attempt_id, runs
        assert state == "ended", runs
        assert outcome == "succeeded", runs
        assert steer == "sent", runs
    with sqlite3.connect(f"file:{folder / 'threads.db'}?mode=ro", uri=True) as db:
        steers = db.execute("SELECT thread_id FROM bee_thread_records WHERE kind = ? AND record_json LIKE ?",
                            ("message", "%tally steer: keep counting%")).fetchall()
    assert steers, "the installed app's steer is not durable on a child thread"
    if HIVE_SOURCE:
        with sqlite3.connect(f"file:{folder / 'governance.db'}?mode=ro", uri=True) as db:
            artifact_digest, source_node = db.execute(
                "SELECT artifact_digest, source_node FROM bee_governance_plans WHERE source_workspace = ? "
                "AND version = ?", (SOURCE, version)).fetchone()
        assert source_node == HIVE_SOURCE, source_node
        (folder / "authored.json").write_text(json.dumps({
            "updated": {"artifact_digest": artifact_digest}, "published_version": version,
            "admission": "rule", "source_workspace": SOURCE, "component": "app." + SOURCE,
            "definition_id": DEFINITION_ID, "workspace_id": workspace_id}, indent=2))
    print("Workspace application: a managed agent authored " + DEFINITION_ID + " from its written spec on the "
          "shipped host profiles, the person saw the threads.read, threads.message, workspace.files.read, "
          "app.database and agents.launch capabilities in Approvals, and the installed scope contained their "
          "generated policies; it called the Threads owner, read a workspace file through its confined volume, "
          "recorded its counts with the greeting in its isolated database, launched the shipped "
          "bee.driver.claude:research_batch child under its generated launch grant, waited for it to settle, read its "
          "result, steered it once with a durable message, and restored its saved count with its rows intact")


if __name__ == "__main__":
    exercise()

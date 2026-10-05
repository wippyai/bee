"""Standalone-binary Workspaces and Claude Agent restart acceptance."""
import argparse
from pathlib import Path
import shutil
import json
import sqlite3
import subprocess
import sys
import tarfile
import tempfile

from native_client import owner_handle
from native_workspace import NativeDesktop
from processes import hold, table
from workspace import name_node

ROOT = Path(__file__).resolve().parents[1]


class AcceptanceFailure(RuntimeError):
    pass


def require(condition, stage):
    if not condition:
        raise AcceptanceFailure(stage)


def environment(folder, home):
    return {
        "PATH": f"{folder / 'bin'}:/usr/bin:/bin",
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "TERM": "xterm-256color",
        "LANG": "C.UTF-8",
        "LC_ALL": "C",
        "TMPDIR": str(folder),
    }


def prepare(folder, label="fresh", source=None):
    source = Path(source or Path(__file__).resolve().parents[1]).resolve()
    root = folder / label
    project = root / "project"
    home = root / "home"
    state = root / "state"
    bin_dir = root / "bin"
    project.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name in (".wippy.yaml", "wippy.yaml", "wippy.lock"):
        shutil.copy2(source / name, project / name)
    for name in ("src", "modules"):
        (project / name).symlink_to(source / name, target_is_directory=True)
    project_wippy = project / ".wippy"
    project_wippy.mkdir()
    (project_wippy / "vendor").symlink_to(source / ".wippy/vendor", target_is_directory=True)
    name_node(project, folder.name)
    login = home / ".claude"
    login.mkdir(mode=0o700)
    (login / ".credentials.json").write_text('{"fixture":"real-build-check"}\n')
    cli = bin_dir / "claude"
    cli.write_text("#!/bin/sh\nif [ \"$1\" = --version ]; then printf '2.1.0 (Claude Code)\\n'; exit 0; fi\nprintf 'BEE_REAL_BUILD_CLAUDE_STARTED\\n'\nIFS= read -r answer\n")
    cli.chmod(0o700)
    state.mkdir(mode=0o700)
    return project, state, home, environment(root, home)


def previous_source(folder, commit):
    repository = Path(__file__).resolve().parents[1]
    source = folder / "previous-source"
    source.mkdir()
    archive_path = folder / "previous-source.tar"
    with archive_path.open("wb") as archive:
        subprocess.run(["git", "archive", "--format=tar", commit,
                        ".wippy.yaml", "wippy.yaml", "wippy.lock", "src", "modules"],
                       cwd=repository, stdout=archive, check=True)
    with tarfile.open(archive_path, "r:") as archive:
        archive.extractall(source)
    archive_path.unlink()
    tooling = source / ".wippy"
    tooling.mkdir()
    (tooling / "vendor").symlink_to(repository / ".wippy/vendor", target_is_directory=True)
    return source


def upgrade_project_sources(project, source, node_name):
    source = Path(source).resolve()
    for name in (".wippy.yaml", "wippy.yaml", "wippy.lock"):
        shutil.copy2(source / name, project / name)
    for name in ("src", "modules"):
        link = project / name
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            shutil.rmtree(link)
        link.symlink_to(source / name, target_is_directory=True)
    name_node(project, node_name)


def stop_fixture_owner(binary, state):
    expected = f"{binary} --state {state} run start"
    for process in table():
        if process.command != expected:
            continue
        handle = hold(process.pid, lambda current: current.command == expected)
        if handle is not None:
            try:
                handle.stop()
            finally:
                handle.close()


def open_workspaces(binary, project, state, home, env, detail, owner=None):
    ui = None
    local_owner = owner
    owns_owner_handle = owner is None
    stage = "create the Bee desktop client"
    try:
        ui = NativeDesktop(binary, project, state, home=home, environment=env)
        stage = "wait for the Bee desktop"
        ui.wait(" BEE ", timeout=90)
        ui.resize(150, 42)
        if local_owner is None:
            stage = "find the retained owner"
            local_owner = owner_handle(ui, binary, state)
        stage = "open the Start menu"
        ui.open_start()
        ui.wait_until(lambda: any("│" in row and "Apps " in row for row in ui.screen.display),
                      "the Start menu", timeout=20)
        ui.choose("Apps")
        ui.choose("Advanced")
        stage = "choose Workspaces"
        ui.choose("Workspaces")
        stage = "wait for Workspaces list"
        ui.wait("WORKSPACES", timeout=45)
        if detail:
            show_workspace_detail(ui)
        retained_ui = ui
        ui = None
        return local_owner, retained_ui
    except Exception:
        client_exited = ui is not None and ui.process.poll() is not None
        if owns_owner_handle and local_owner is not None:
            local_owner.close()
        stop_fixture_owner(binary, state)
        screen = " ".join(ui.text().split())[-500:] if ui is not None else ""
        raise AcceptanceFailure("Workspaces: " + stage + "; client exited=" + str(client_exited)
                                + ("; screen=" + screen if screen else "")) from None
    finally:
        if ui is not None:
            ui.close()


def show_workspace_detail(ui):
    ui.key(b"d")
    ui.wait_until(
        lambda: any(marker in ui.text() for marker in (
            "AGENT SESSIONS", "native listener changed", "Could not inspect this workspace", "Workspaces unavailable:")),
        "the selected workspace extension", timeout=45)
    visible = ui.text()
    require("AGENT SESSIONS" in visible, "Workspaces detail omitted the Agent sessions extension")
    require("native listener changed" not in visible, "Workspaces retained a stale native listener")
    require("Could not inspect this workspace" not in visible, "Workspaces detail reported an inspection error")
    require("Workspaces unavailable:" not in visible, "Workspaces could not open its gateway extension")


def close_workspaces(ui):
    ui.key(b"\x17")
    ui.wait("SESSIONS", timeout=20)
    ui.key(b"\x17")
    ui.wait("No applications open", timeout=20)
    ui.quit()


def open_claude_agent(binary, project, state, home, env, owner=None):
    ui = None
    local_owner = owner
    owns_owner_handle = owner is None
    stage = "start the Agent window"
    try:
        ui = NativeDesktop(binary, project, state, arguments=("agent",), home=home, environment=env)
        stage = "wait for Sessions on the second display"
        ui.wait("SESSIONS", timeout=90)
        if local_owner is None:
            local_owner = owner_handle(ui, binary, state)
        ui.key(b"n")
        stage = "wait for the new-session picker"
        ui.wait("NEW SESSION", timeout=45)
        ui.key(b"/Claude\r")
        ui.wait_until(lambda: any(row.lstrip().startswith("›") and "Claude" in row for row in ui.screen.display),
                      "the selected Claude profile", timeout=45)
        stage = "open the Claude profile"
        ui.key(b"m")
        ui.wait("BEE_REAL_BUILD_CLAUDE_STARTED", timeout=60)
        stage = "close the Claude Agent window"
        ui.key(b"\x17")
        ui.wait("SESSIONS", timeout=20)
        ui.key(b"\x17")
        ui.wait("No applications open", timeout=20)
        ui.quit()
        return local_owner
    except Exception:
        if owns_owner_handle and local_owner is not None:
            local_owner.close()
        screen = " ".join(ui.text().split())[-500:] if ui is not None else ""
        raise AcceptanceFailure("Claude Agent: " + stage + ("; screen=" + screen if screen else "")) from None
    finally:
        if ui is not None:
            ui.close()


def stop_owner(binary, state, home, env, owner):
    try:
        result = subprocess.run([binary, "--state", str(state), "stop"], cwd=home,
                                env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=60)
        require(result.returncode == 0 and "Bee stopped" in result.stdout, "Bee stop failed")
        require(owner.exited(timeout=20), "Bee stop left its owner running")
    finally:
        owner.close()


def round_trip(binary, project, state, home, env, workspaces_first):
    owner = None
    workspace_ui = None
    try:
        if workspaces_first:
            owner, workspace_ui = open_workspaces(binary, project, state, home, env, detail=True)
            open_claude_agent(binary, project, state, home, env, owner)
        else:
            owner, workspace_ui = open_workspaces(binary, project, state, home, env, detail=False)
            open_claude_agent(binary, project, state, home, env, owner)
            show_workspace_detail(workspace_ui)
        close_workspaces(workspace_ui)
        return owner
    except Exception:
        if workspace_ui is not None:
            workspace_ui.close()
        if owner is not None:
            owner.close()
        stop_fixture_owner(binary, state)
        raise


def retained_state(state):
    with sqlite3.connect(state / "workspace.db") as database:
        rows = database.execute("SELECT value FROM workspace_state").fetchall()
        ledger = database.execute("SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id").fetchall()
    applications = {
        item["id"]: (item["definition_id"], item["instance_id"])
        for row in rows for item in json.loads(row[0])["applications"]
    }
    return applications, ledger


def exercise(binary, previous, previous_commit):
    temporary_root = ROOT / ".wippy/tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-real-build-check-", dir=temporary_root) as temporary:
        folder = Path(temporary)
        project, state, home, env = prepare(folder, "fresh")
        try:
            owner = round_trip(binary, project, state, home, env, workspaces_first=False)
            print("Real standalone fresh-state Workspaces and Claude Agent passed", flush=True)
            stop_owner(binary, state, home, env, owner)
            owner = round_trip(binary, project, state, home, env, workspaces_first=True)
            print("Real standalone restarted-state Workspaces and Claude Agent passed", flush=True)
            stop_owner(binary, state, home, env, owner)

            if previous is not None:
                if previous_commit is None:
                    raise AcceptanceFailure("prior binary requires its matching source commit for the upgrade leg")
                pinned_source = previous_source(folder, previous_commit)
                upgrade_project, upgrade_state, upgrade_home, upgrade_env = prepare(
                    folder, "upgrade", source=pinned_source)
                # Seed the prior build's Workspaces and a restorable Settings checkpoint.
                # Agent on a second display is the regression being fixed here.
                prior_owner, prior_ui = open_workspaces(previous, upgrade_project, upgrade_state,
                                                       upgrade_home, upgrade_env, detail=True)
                try:
                    prior_ui.open_start()
                    prior_ui.wait_until(lambda: any("│" in row and "Settings/Help" in row for row in prior_ui.screen.display),
                                        "the Settings menu", timeout=20)
                    prior_ui.choose("Settings/Help")
                    prior_ui.choose("Settings")
                    prior_ui.wait("BEE SETTINGS", timeout=45)
                    prior_ui.wait_until(lambda: any(value[0] == "bee.settings.app:app" for value in retained_state(upgrade_state)[0].values()),
                                        "the Settings checkpoint", timeout=20)
                    prior_ui.quit()
                finally:
                    prior_ui.close()
                stop_owner(previous, upgrade_state, upgrade_home, upgrade_env, prior_owner)
                prior_apps, prior_ledger = retained_state(upgrade_state)
                require(any(value[0] == "bee.settings.app:app" for value in prior_apps.values()),
                        "prior build did not retain Settings")
                upgrade_project_sources(upgrade_project, ROOT, folder.name)
                upgraded_owner, upgraded_ui = open_workspaces(binary, upgrade_project, upgrade_state,
                                                             upgrade_home, upgrade_env, detail=True)
                try:
                    current_apps, current_ledger = retained_state(upgrade_state)
                    require(all(current_apps.get(identity) == value for identity, value in prior_apps.items()),
                            "upgrade changed a retained application or instance identity")
                    require(current_ledger == prior_ledger, "upgrade changed the applied migration ledger")
                    upgraded_ui.key(b"\x17")
                    upgraded_ui.wait_until(lambda: "▣ Settings" in upgraded_ui.screen.display[0],
                                           "the restored Settings tab", timeout=20)
                    settings_x = upgraded_ui.screen.display[0].index("▣ Settings") + 4
                    upgraded_ui.mouse(0, settings_x, 1)
                    upgraded_ui.wait("BEE SETTINGS", timeout=20)
                    upgraded_ui.key(b"\x17")
                    upgraded_ui.wait_until(lambda: "No applications open" in upgraded_ui.text() or "SESSIONS" in upgraded_ui.text(),
                                           "the desktop after closing Settings", timeout=20)
                    if "SESSIONS" in upgraded_ui.text():
                        upgraded_ui.key(b"\x17")
                    upgraded_ui.wait("No applications open", timeout=20)
                    upgraded_ui.quit()
                finally:
                    upgraded_ui.close()
                    stop_owner(binary, upgrade_state, upgrade_home, upgrade_env, upgraded_owner)
                upgraded_owner = round_trip(binary, upgrade_project, upgrade_state, upgrade_home, upgrade_env, workspaces_first=True)
                stop_owner(binary, upgrade_state, upgrade_home, upgrade_env, upgraded_owner)
                print("Real standalone main-created-state Workspaces and Claude Agent passed; restored Settings application/instance IDs and migration checksums unchanged", flush=True)
            else:
                print("Real standalone prior-build upgrade: skipped (no previous binary supplied)", flush=True)
        except Exception:
            stop_fixture_owner(binary, state)
            if previous is not None:
                stop_fixture_owner(previous, folder / "upgrade" / "state")
                stop_fixture_owner(binary, folder / "upgrade" / "state")
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=lambda value: str(Path(value).resolve()))
    parser.add_argument("--previous", type=lambda value: str(Path(value).resolve()))
    parser.add_argument("--previous-commit")
    args = parser.parse_args()
    try:
        exercise(args.binary, args.previous, args.previous_commit)
    except Exception as error:
        print(f"Real standalone acceptance failed: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()

"""Standalone-binary Workspaces and Claude Agent restart acceptance."""
import os

os.environ.clear()
os.environ.update(PATH="/usr/bin:/bin", LC_ALL="C", LANG="C.UTF-8")

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from native_client import owner_handle
from native_workspace import NativeDesktop
from processes import hold, table
from workspace import name_node


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
    cli.write_text("#!/bin/sh\nprintf 'BEE_REAL_BUILD_CLAUDE_STARTED\\n'\nIFS= read -r answer\n")
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
        ui.choose("Tools")
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
    ui.key(b"\r")
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
    ui.wait("No applications open", timeout=20)
    ui.quit()


def open_claude_agent(binary, project, state, home, env, owner=None):
    ui = None
    local_owner = owner
    owns_owner_handle = owner is None
    stage = "start the Agent window"
    try:
        ui = NativeDesktop(binary, project, state, arguments=("agent",), home=home, environment=env)
        stage = "wait for the profile list"
        ui.wait("Choose a profile", timeout=90)
        if local_owner is None:
            local_owner = owner_handle(ui, binary, state)
        ui.wait("Claude", timeout=45)
        stage = "move the selection to Claude"
        ui.key(b"\x1b[B")
        stage = "wait for the Claude summary"
        ui.wait("Configured folder", timeout=20)
        stage = "wait for Claude's tools summary"
        ui.wait("tools configured", timeout=20)
        stage = "open the Claude profile"
        ui.key(b"\r")
        ui.wait("BEE_REAL_BUILD_CLAUDE_STARTED", timeout=60)
        stage = "close the Claude Agent window"
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


def exercise(binary, previous, previous_commit):
    with tempfile.TemporaryDirectory(prefix="bee-real-build-check-") as temporary:
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
                prior_owner = round_trip(previous, upgrade_project, upgrade_state, upgrade_home, upgrade_env, workspaces_first=False)
                print("Real standalone previous-build Workspaces and Claude Agent passed", flush=True)
                stop_owner(previous, upgrade_state, upgrade_home, upgrade_env, prior_owner)
                upgrade_project_sources(upgrade_project, Path(__file__).resolve().parents[1], folder.name)
                upgraded_owner = round_trip(binary, upgrade_project, upgrade_state, upgrade_home, upgrade_env, workspaces_first=True)
                stop_owner(binary, upgrade_state, upgrade_home, upgrade_env, upgraded_owner)
                print("Real standalone upgraded-state Workspaces and Claude Agent passed", flush=True)
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

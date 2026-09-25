"""A running desktop shows another workspace from its workspace menu without detaching."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time

from native_workspace import NativeDesktop, STATE_ENVIRONMENT
from native_client import owner_handle, stop_owner
from workspace import classic_workspace


def add_workspace(binary, folder, state, label, subpath):
    """Create one more catalog workspace in a new folder under the node's folder with bee workspace create."""
    env = {key: value for key, value in os.environ.items() if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
    env.update(HOME=str(folder), PATH=f'{folder}/bin:/usr/bin:/bin', XDG_CONFIG_HOME=str(folder / '.config'))
    created = subprocess.run([str(binary), '--state', str(state), 'workspace', 'create', label, 'bee.env:workspace_root/' + subpath,
                              '--new-folder'], cwd=folder, env=env, capture_output=True, text=True, timeout=120)
    assert created.returncode == 0, created.stdout + created.stderr
    line = created.stdout.strip().splitlines()[-1]
    assert line.startswith('Created '), created.stdout
    workspace_id = line.split()[1]
    assert (folder / subpath).is_dir(), 'bee workspace create did not make the folder'
    listed = subprocess.run([str(binary), '--state', str(state), 'workspace', 'list'], cwd=folder, env=env,
                            capture_output=True, text=True, timeout=120)
    assert listed.returncode == 0 and workspace_id in listed.stdout, listed.stdout + listed.stderr
    return workspace_id


def shows(ui, workspace_id):
    """The connection panel's details name the workspace this display shows."""
    ui.key(b'\x1b[20~')  # F9 opens the connection panel.
    ui.wait('CONNECTION', timeout=10)
    # D toggles the details; a presenter keeps them open from an earlier look.
    if 'Less [D]' not in ui.text():
        ui.key(b'd')
    ui.wait(workspace_id, timeout=10)
    ui.key(b'\x1b')


def shown_label(ui):
    """The workspace name in the top bar of the display the client presents."""
    top = ui.text().splitlines()[0]
    return top.split('Workspace ', 1)[1].split('▾', 1)[0].strip() if 'Workspace ' in top else ''


def await_other_workspace(ui, before, timeout=30):
    """The client presents the display of another workspace without leaving."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and ui.process.poll() is None:
        ui.pump()
        label = shown_label(ui)
        if label and label != before and 'WORKSPACES' not in ui.text():
            return
    assert ui.process.poll() is None, 'The client left instead of switching'
    raise AssertionError('The display did not switch: ' + ui.text())


def switch(ui, target_row):
    """Open the workspace menu from the connection panel and choose one row."""
    ui.key(b'\x1b[20~')  # F9 opens the connection panel.
    ui.wait('Workspaces [W]', timeout=10)
    ui.key(b'w')
    ui.wait('WORKSPACES', timeout=10)
    ui.wait(target_row, timeout=10)
    rows = [row for row in ui.text().splitlines() if '●' in row or target_row in row]
    marked = next(index for index, row in enumerate(rows) if target_row in row)
    current = next(index for index, row in enumerate(rows) if '●' in row)
    step = b'\x1b[B' if marked > current else b'\x1b[A'
    for _ in range(abs(marked - current)):
        ui.key(step)
    ui.key(b'\r')


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-workspace-switch-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        owner = None
        ui = NativeDesktop(binary, folder, state)
        try:
            ui.wait(' BEE ', timeout=20)
            owner = owner_handle(ui, binary, state)
            folder_id = classic_workspace(state / 'workspace.db')
            second = add_workspace(binary, folder, state, 'Second', 'second')
            shows(ui, folder_id)
            before = shown_label(ui)
            switch(ui, 'Second')
            # The display now shows the other workspace; the client stayed attached.
            await_other_workspace(ui, before)
            shows(ui, second)
            ui.open_start()
            ui.choose('Terminal')
            ui.wait('$ ', timeout=15)
            ui.key(b"printf 'SWITCHED_%s\\n' HERE\r")
            ui.wait('SWITCHED_HERE', timeout=10)
            before = shown_label(ui)
            switch(ui, folder_id[:8])
            await_other_workspace(ui, before)
            shows(ui, folder_id)
            # The first workspace's terminal session is where it was left.
            assert 'SWITCHED_HERE' not in ui.text(), ui.text()
            ui.quit()
        finally:
            ui.close()
            stop_owner(owner)
    print('Native workspace switch: the workspace menu moved a running display to another workspace and back without detaching')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

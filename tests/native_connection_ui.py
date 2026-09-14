"""Standalone Hive status comes from its supervisor-selected desktop context."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time
from native_workspace import NativeDesktop, STATE_ENVIRONMENT
from native_client import owner_handle, stop_owner


def attachment(ui):
    rows = [row for row in ui.text().splitlines() if 'ATTACH' in row]
    if not rows:
        return None
    assert len(rows) == 1, ui.text()
    return rows[0].split('ATTACH', 1)[1].rsplit('│', 1)[0].strip()


def wait_attachment(ui, expected, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ui.pump()
        if attachment(ui) == expected:
            return
    assert attachment(ui) == expected, ui.text()


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-connection-ui-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        owner = None
        observer = None
        env = {key: value for key, value in os.environ.items()
               if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
        env.update(HOME=str(folder), TERM='xterm-256color')

        def catalog():
            result = subprocess.run(
                [str(binary), '--state-dir', str(state), 'desktops'],
                cwd=folder, env=env, stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            lines = result.stdout.splitlines()
            assert lines and lines[0].startswith('WORKSPACE'), result.stdout
            return [line.split() for line in lines[1:]]

        ui = NativeDesktop(binary, folder, state)
        try:
            ui.wait(' BEE ', timeout=15)
            owner = owner_handle(ui, binary, state)
            ui.open_start()
            ui.choose('Tools')
            ui.choose('Hive Manager')
            ui.wait('HIVE MANAGER')
            ui.wait('Display ', timeout=10)
            assert 'destination node is not configured' not in ui.text(), ui.text()
            assert 'client' in ui.text(), ui.text()
            ui.key(b'\x1b[20;3~')  # Alt+F9 retains the window minimize shortcut.
            ui.wait('− Hive Manager')
            assert 'CONNECTION' not in ui.text(), ui.text()
            ui.mouse(0, 12, 1)
            ui.mouse(0, 12, 1, True)
            ui.wait('HIVE MANAGER')
            ui.key(b'\x1b[20~')
            ui.wait('CONNECTION')
            ui.wait('Supervisor ready')
            for label in ('NODE', 'ATTACH', 'WORKSPACE', 'DISPLAY'):
                assert label in ui.text(), ui.text()
            before = ui.text().splitlines()
            display = next(before[i + 1].strip() for i, row in enumerate(before) if 'DISPLAY' in row)
            assert 'Current session' not in display, display
            Path('/tmp/bee-native-connection-ui-frame.txt').write_text(ui.text())
            ui.key(b'\x1b')
            ui.quit()
            ui.close()
            ui = NativeDesktop(binary, folder, state)
            ui.wait(' BEE ', timeout=15)
            ui.key(b'\x1b[20~')
            ui.wait('Supervisor ready')
            wait_attachment(ui, 'Controlled')
            rows = catalog()
            assert len(rows) == 1 and len(rows[0]) == 3 and rows[0][2] == 'yes', rows
            workspace, display_id = rows[0][:2]
            observer = NativeDesktop(binary, folder, state, arguments=('observe', workspace, display_id))
            observer.wait(' BEE ', timeout=15)
            wait_attachment(ui, 'Controlled · 1 observer')
            wait_attachment(observer, 'Controlled · 1 observer')
            observer.quit()
            observer.close()
            observer = None
            wait_attachment(ui, 'Controlled')
            assert display in ui.text(), ui.text()
            ui.key(b'\x1b')
            ui.quit()
        finally:
            if observer is not None:
                observer.close()
            ui.close()
            stop_owner(owner)
    print('Native connection UI: supervisor readiness, exact identities and live controller/observer projection passed')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

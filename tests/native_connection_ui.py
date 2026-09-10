"""Standalone Hive status comes from its supervisor-selected desktop context."""
from pathlib import Path
import sys
import tempfile
from native_workspace import NativeDesktop
from native_client import owner_handle, stop_owner


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-connection-ui-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        owner = None
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
            ui.wait('Service running')
            for label in ('NODE', 'WORKSPACE', 'DISPLAY'):
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
            ui.wait('Service running')
            assert display in ui.text(), ui.text()
            ui.key(b'\x1b')
            ui.quit()
        finally:
            ui.close()
            stop_owner(owner)
    print('Native connection UI: supervisor-backed Hive status, node/workspace/display identity and retained display on reconnect passed')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

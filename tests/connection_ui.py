"""Connection dropdown owns input and displays the actual desktop identities."""
from pathlib import Path
import tempfile
import re
import time
from tui_smoke import Desktop


def exercise(packed=False):
    with tempfile.TemporaryDirectory(prefix='bee-connection-ui-') as directory:
        ui = Desktop(directory, packed=packed)
        try:
            ui.wait(' BEE ')
            ui.key(b'\x1b[20~')  # F9
            ui.wait('CONNECTION')
            for label in ('HIVE', 'NODE', 'WORKSPACE', 'DISPLAY'):
                assert label in ui.text(), ui.text()
            assert 'Not reported' in ui.text(), ui.text()
            assert not re.findall(r'(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])', ui.text()), ui.text()
            Path('/tmp/bee-connection-compact-frame.txt').write_text(ui.text())
            # Clicking inside the card keeps it open; Details is a real hit target.
            ui.mouse(0, 60, 3)
            ui.mouse(0, 60, 3, True)
            ui.pump(.1)
            assert 'CONNECTION' in ui.text(), ui.text()
            ui.mouse(0, 60, 13)
            ui.mouse(0, 60, 13, True)
            ui.wait('Less [D]')
            identities = re.findall(r'(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])', ui.text())
            assert len(set(identities)) >= 2, 'Full workspace/display IDs were clipped: ' + ui.text()
            ui.key(b'\x1b')
            ui.pump(.2)
            assert 'CONNECTION' not in ui.text(), ui.text()
            # The existing workspace affordance opens the same surface.
            ui.mouse(0, 94, 1)
            ui.mouse(0, 94, 1, True)
            ui.wait('CONNECTION')
            ui.key(b'\x1b[24~')  # F12 must remain available with the dropdown open.
            deadline = time.monotonic() + 4
            while 'CONNECTION' in ui.text() and time.monotonic() < deadline:
                ui.pump(.05)
            assert 'CONNECTION' not in ui.text(), ui.text()
            ui.key(b'\x1b[20~')
            ui.wait('CONNECTION')
            ui.key(b'd')
            ui.wait('Less [D]')
            assert all(identity in ui.text() for identity in identities), 'F12 changed displayed identities'
            Path('/tmp/bee-connection-dropdown-frame.txt').write_text(ui.text())
            ui.resize(42, 12)
            ui.pump(.3)
            for label in ('HIVE', 'NODE', 'WORKSPACE', 'DISPLAY'):
                assert label in ui.text(), ui.text()
            assert all(len(row) <= 42 for row in ui.screen.display), ui.text()
            ui.resize(100, 30)
            ui.pump(.3)
            ui.key(b'\x1b')
            ui.quit()
        finally:
            ui.close()
    print(f'Connection dropdown {"pack" if packed else "source"}: identities, honest unknown Hive, mouse/F9, Escape and F12 passed')


if __name__ == '__main__':
    exercise()
    exercise(True)

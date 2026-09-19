"""Real PTY navigation byte matrix through the desktop, viewport and proxy."""
import shutil
import tempfile
from pathlib import Path
import yaml

from tui_smoke import Desktop, ROOT

# Shell-owned F1/F11/F12 and Alt+Tab remain shell controls and are tested there.
# These sequences belong to the focused application, including their modifiers.
cases = []
for application in (False, True):
    for code in ('A', 'B', 'C', 'D', 'H', 'F', '2~', '3~', '5~', '6~'):
        for mask in range(8):
            if mask:
                sequence = ('\x1b[' + code[:-1] + ';' + str(mask + 1) + '~') if code.endswith('~') else ('\x1b[1;' + str(mask + 1) + code)
            else:
                sequence = '\x1b[' + code
            expected = '\x1bO' + code if application and not mask and len(code) == 1 else sequence
            cases.append((application, sequence.encode(), expected.encode()))
cases.append((False, b'\x1b[Z', b'\x1b[Z'))

with tempfile.TemporaryDirectory(prefix='bee-navigation-') as temporary:
    folder = Path(temporary)
    project = folder / 'project'
    shutil.copytree(ROOT / 'src', project / 'src')
    for name in ('wippy.lock', '.wippy.yaml', 'wippy.yaml'):
        shutil.copy2(ROOT / name, project / name)
    index = project / 'src/apps/console/_index.yaml'
    document = yaml.safe_load(index.read_text())
    executor = next(entry for entry in document['entries'] if entry['name'] == 'executor')
    executor['default_env'].update({'HOME': str(folder), 'HISTFILE': '/dev/null', 'PS1': '$ '})
    index.write_text(yaml.safe_dump(document, sort_keys=False))
    reader = folder / 'read_keys.py'
    reader.write_text('''import os, select, termios, time, tty
cases = ''' + repr(cases) + '''
saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    for index, (application, _, expected) in enumerate(cases):
        os.write(1, b'\\x1b[?1h' if application else b'\\x1b[?1l')
        os.write(1, ('\\r\\nNAV_READY_%d\\r\\n' % index).encode())
        received = b''
        deadline = time.monotonic() + 3
        while len(received) < len(expected) and time.monotonic() < deadline:
            if select.select([0], [], [], .05)[0]:
                received += os.read(0, 128)
        if received != expected:
            os.write(1, ('\\r\\nNAV_FAIL_%d got=%s expected=%s\\r\\n' % (index, received.hex(), expected.hex())).encode())
            raise SystemExit(1)
    os.write(1, b'\\r\\nNAV_COMPLETE\\r\\n')
finally:
    os.write(1, b'\\x1b[?1l')
    termios.tcsetattr(0, termios.TCSANOW, saved)
''')
    ui = Desktop(folder, project=project, apps=('bee.console:app',))
    try:
        ui.wait('Terminal')
        ui.key(('python3 ' + str(reader) + '\r').encode())
        for index, (_, sequence, _) in enumerate(cases):
            ui.wait('NAV_READY_%d' % index)
            ui.key(sequence)
        ui.wait('NAV_COMPLETE')
        ui.quit(confirm=True)
    finally:
        ui.close()
print('Navigation: 161 real PTY cases; arrows, Home/End, Insert/Delete, Page Up/Down, all modifier combinations, application cursor mode, Shift+Tab')

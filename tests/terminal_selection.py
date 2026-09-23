"""Real PTY selection/copy: one focused body, explicit OSC52, no replay."""
import base64
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
import yaml

from tui_smoke import Desktop, ROOT, RUNTIME
from workspace import pack_deployment


def copies(ui, start):
    return [base64.b64decode(value, validate=True).decode('utf-8')
            for value in re.findall(rb'\x1b\]52;c;([A-Za-z0-9+/=]*)\x07', bytes(ui.raw[start:]))]


def locate(ui, marker):
    for y, line in enumerate(ui.screen.display, 1):
        if marker in line:
            return line.index(marker) + 1, y
    raise AssertionError(f'Missing selection marker {marker}\n{ui.text()}')


def begin(ui, marker, *, title=False):
    x, y = locate(ui, marker)
    menu_x, menu_y = x, y
    if title:
        titles = [(row, line) for row, line in enumerate(ui.screen.display, 1)
                  if row < y and '×' in line and 'Terminal' in line]
        menu_y, line = titles[-1]
        menu_x = line.index('Terminal') + 1
    ui.mouse(2, menu_x, menu_y)
    ui.mouse(2, menu_x, menu_y, True)
    ui.wait('Select text')
    ui.choose('Select text')
    ui.wait('drag to select')
    return x, y


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix='bee-selection-') as temporary:
        folder = Path(temporary)
        project = folder / 'project'
        shutil.copytree(ROOT / 'src', project / 'src')
        shutil.copytree(ROOT / 'modules', project / 'modules')
        for name in ('wippy.lock', '.wippy.yaml', 'wippy.yaml'):
            shutil.copy2(ROOT / name, project / name)
        index = project / 'src/apps/console/_index.yaml'
        document = yaml.safe_load(index.read_text())
        executor = next(entry for entry in document['entries'] if entry['name'] == 'executor')
        executor['default_env'].update({'HOME': str(folder), 'HISTFILE': '/dev/null', 'PS1': '$ '})
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        pack = project / 'selection-deployment'
        if packed:
            pack_deployment(project, pack)
        ui = Desktop(folder, packed, project=project, deployment=pack,
                     apps=('bee.console:app',))
        try:
            ui.wait('Terminal')
            # Open two distinct instances; positional launch aliases deduplicate.
            ui.key(b"clear; printf 'BACKGROUND_%s\\n' PRIVATE\r")
            ui.wait('BACKGROUND_PRIVATE')
            ui.key(b'\x0e')
            ui.pump(.5)
            ui.key(b"clear; printf 'FOREGROUND_%s\\n' SELECTABLE; (sleep 3; printf '\\033[2J\\033[HCHANGED_OWNER_OUTPUT\\n') &\r")
            ui.wait('FOREGROUND_SELECTABLE')
            assert ui.screen.display[0].count('Terminal') == 2, ui.text()
            # Shift-right-click remains available to the application body.
            mx, my = locate(ui, 'FOREGROUND_SELECTABLE')
            ui.mouse(6, mx, my)
            ui.mouse(6, mx, my, True)
            ui.pump(.1)
            assert 'Select text' not in ui.text(), 'Shift-right-click opened the desktop menu'
            x, y = begin(ui, 'FOREGROUND_SELECTABLE')
            start = len(ui.raw)
            ui.mouse(0, x, y)
            ui.mouse(32, x + len('FOREGROUND_SELECTABLE') - 1, y)
            ui.mouse(0, x + len('FOREGROUND_SELECTABLE') - 1, y, True)
            ui.pump(3.5)
            assert 'FOREGROUND_SELECTABLE' in ui.text(), 'New app output changed the frozen selection'
            assert 'CHANGED_OWNER_OUTPUT' not in ui.text(), 'Live content leaked into selected snapshot'
            # Hover after release must not change the selected range.
            ui.mouse(35, x + 2, y + 2)
            ui.key(b'\x03')
            ui.wait('Clipboard request submitted')
            assert copies(ui, start) == ['FOREGROUND_SELECTABLE'], (copies(ui, start), ui.text())
            ui.wait('CHANGED_OWNER_OUTPUT')
            ui.key(b"printf 'SELECTION_%s\\n' INPUT_OK\r")
            ui.wait('SELECTION_INPUT_OK')
            # Cancel a later range; no further side effect may appear on rejoin.
            x, y = begin(ui, 'SELECTION_INPUT_OK', title=True)
            start = len(ui.raw)
            ui.mouse(0, x, y)
            ui.mouse(0, x + 8, y, True)
            ui.key(b'\x1b')
            ui.key(b'\x1b[24~')
            ui.wait('SELECTION_INPUT_OK')
            ui.pump(.5)
            assert copies(ui, start) == [], 'Canceled selection replayed clipboard data'
            x, y = begin(ui, 'SELECTION_INPUT_OK')
            ui.mouse(0, x, y)
            ui.mouse(0, x + 8, y, True)
            start = len(ui.raw)
            ui.resize(98, 29)
            ui.key(b'\x03')
            assert copies(ui, start) == [], 'Resized selection submitted stale clipboard data'
            ui.quit(confirm=True)
            print(f"Selection {'pack' if packed else 'source'}: focused copy, frozen output, hover, input, cancel/rejoin, resize")
        finally:
            ui.close()


if __name__ == '__main__':
    exercise(False)
    exercise(True)

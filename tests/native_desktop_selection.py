"""Explicit native selection uses owner IDs and never allocates on refusal."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

from native_workspace import NativeDesktop, STATE_ENVIRONMENT
from native_client import owner_handle, stop_owner


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-explicit-desktop-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        clients = []
        owner = None
        env = {key: value for key, value in os.environ.items()
               if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
        env.update(HOME=str(folder), TERM='xterm-256color')

        def client(*args):
            ui = NativeDesktop(binary, folder, state, arguments=args)
            clients.append(ui)
            return ui

        def command(*args):
            return subprocess.run([str(binary), '--state-dir', str(state), *args],
                                  cwd=folder, env=env, stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=15)

        def catalog():
            result = command('desktops')
            assert result.returncode == 0, result.stderr
            lines = result.stdout.splitlines()
            assert lines and lines[0].startswith('WORKSPACE'), result.stdout
            return [line.split() for line in lines[1:]]

        try:
            first = client()
            first.wait(' BEE ', timeout=15)
            owner = owner_handle(first, binary, state)
            first.open_start()
            first.choose('Terminal')
            first.wait('$ ')
            first.key(b"clear; printf 'FIRST_%s\\n' READY\r")
            first.wait('FIRST_READY')
            second = client()
            second.wait(' BEE ', timeout=15)
            second.open_start()
            second.choose('Terminal')
            second.wait('$ ')
            second.key(b"BEE_SELECTED=retained; clear; printf 'SECOND_%s\\n' READY\r")
            second.wait('SECOND_READY')
            identities = catalog()
            assert len(identities) == 2, identities
            selected = next(row for row in identities if len(row) == 2)
            workspace, display = selected
            observer = client('observe', workspace, display)
            observer.wait('SECOND_READY', timeout=15)
            assert 'FIRST_READY' not in observer.text(), observer.text()
            observer.quit()
            refused = command('attach', workspace, display)
            assert refused.returncode != 0 and 'DESKTOP_CONTROLLED' in refused.stderr, refused
            assert catalog() == identities, 'Refused explicit control allocated a desktop'
            foreign = command('attach', 'f' * 32, display)
            assert foreign.returncode != 0, foreign
            assert catalog() == identities, 'Foreign selection changed the catalog'
            second.quit()
            joined = client('attach', workspace, display)
            joined.wait('SECOND_READY', timeout=15)
            joined.key(b"printf 'EXPLICIT_%s\\n' \"$BEE_SELECTED\"\r")
            joined.wait('EXPLICIT_retained')
            assert catalog() == identities, 'Explicit rejoin allocated a desktop'
            joined.quit()
            first.key(b"printf 'FIRST_STILL_%s\\n' READY\r")
            first.wait('FIRST_STILL_READY')
            first.quit()
        finally:
            for ui in reversed(clients):
                ui.close()
            stop_owner(owner)
    print('Explicit native desktops: authenticated listing, selected observer, controlled/foreign refusal without allocation, exact retained-shell rejoin passed')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

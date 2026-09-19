"""The real host-admitted Hive Manager reads retained display identities only."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
from contextlib import ExitStack
from native_workspace import NativeDesktop, STATE_ENVIRONMENT
from native_client import owner_handle, stop_owner


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-live-catalog-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        env = {key: value for key, value in os.environ.items()
               if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
        env.update(HOME=str(folder), TERM='xterm-256color')
        owner = None
        clients = []

        def catalog():
            result = subprocess.run([str(binary), '--state', str(state), 'desktops'],
                                    cwd=folder, env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, result.stderr
            return result.stdout

        try:
            first = NativeDesktop(binary, folder, state)
            clients.append(first)
            first.wait(' BEE ', timeout=15)
            owner = owner_handle(first, binary, state)
            second = NativeDesktop(binary, folder, state)
            clients.append(second)
            second.wait(' BEE ', timeout=15)
            before = catalog()
            rows = [line.split() for line in before.splitlines()[1:]]
            assert len(rows) == 2, before
            first.resize(220, 45)
            first.open_start()
            first.choose('Tools')
            first.choose('Hive Manager')
            first.wait('HIVE MANAGER')
            first.window_control('□')
            first.wait('display', timeout=10)
            first.key(b'\r')
            first.wait('controller unknown', timeout=10)
            assert 'Desktops unavailable:' not in first.text(), first.text()
            first.key(b't')  # Details exposes exact identities for comparison.
            for row in rows:
                first.wait(row[1], timeout=5)
            assert catalog() == before, 'Reading the directory allocated or removed a display'
            first.key(b'\x1b[24~')
            first.wait('controller unknown', timeout=10)
            assert catalog() == before, 'Presenter replacement changed durable display identities'
            first.quit()
            second.quit()
        finally:
            with ExitStack() as cleanup:
                cleanup.callback(stop_owner, owner)
                for client in clients:
                    cleanup.callback(client.close)
    print('Live Hive catalog: two retained identities, unknown occupancy, read-only listing and F12 passed')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

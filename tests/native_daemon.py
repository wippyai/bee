"""A daemon on a new node database composes and lists no folder workspace."""
from pathlib import Path
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

from native_workspace import NativeDesktop, STATE_ENVIRONMENT


def ready(process, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if not line:
            break
        if line.startswith('BEE_DAEMON_READY '):
            return line.split()
    raise AssertionError(f'The daemon did not report readiness; exit={process.poll()}')


def workspaces(state):
    with sqlite3.connect(state / 'workspace.db') as db:
        return db.execute('SELECT workspace_id, root_ref, subpath FROM workspaces').fetchall()


def exercise(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-daemon-') as directory:
        folder = Path(directory)
        state = folder / 'state'
        env = {key: value for key, value in os.environ.items()
               if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
        env.update(HOME=str(folder), TERM='xterm-256color')
        daemon = subprocess.Popen([str(binary), '--state', str(state), 'daemon'], cwd=folder, env=env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, start_new_session=True)
        client = None
        try:
            ready(daemon)
            # A client of the daemon picks among the node's workspaces: none.
            # Its listing opens and migrates the node catalog.
            client = NativeDesktop(binary, folder, state, arguments=('client',))
            client.wait('Bee workspaces', timeout=30)
            client.wait('No workspaces match', timeout=10)
            client.key(b'\x1b')
            client.close()
            client = None
            assert workspaces(state) == [], workspaces(state)
        finally:
            if client is not None:
                client.close()
            if daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGTERM)
                try:
                    daemon.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(daemon.pid, signal.SIGKILL)
                    daemon.wait()
    print('Native daemon: a new node database holds and offers no folder workspace')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve())

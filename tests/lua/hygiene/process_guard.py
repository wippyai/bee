"""Keep each shard's orphaned OS children attributable to that shard."""
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

RECORD = Path('.wippy/process-guard.json')


def descendants(rows, root, excluded=()):
    found = set()
    frontier = {root}
    while frontier:
        children = {pid for pid, row in rows.items() if row['parent'] in frontier}
        children -= found | set(excluded)
        children = {pid for pid in children if not (rows[pid].get('state') == 'Z' and rows[pid]['parent'] == root)}
        found.update(children)
        frontier = children
    return {f"os:{pid}:{rows[pid]['start']}": {'source': 'OS ' + rows[pid]['name']}
            for pid in sorted(found)}


def snapshot(root, excluded=()):
    rows = {}
    frontier = {root}
    visited = set(excluded)
    while frontier:
        children = set()
        for parent in frontier - visited:
            visited.add(parent)
            try:
                tasks = list(Path(f'/proc/{parent}/task').iterdir())
            except (FileNotFoundError, ProcessLookupError):
                continue
            for task in tasks:
                try:
                    children.update(int(pid) for pid in (task / 'children').read_text().split())
                except (FileNotFoundError, ProcessLookupError):
                    continue
        frontier = children - visited
        for pid in frontier:
            try:
                value = Path(f'/proc/{pid}/stat').read_text()
            except (FileNotFoundError, ProcessLookupError):
                continue
            name, rest = value.split('(', 1)[1].rsplit(')', 1)
            fields = rest.split()
            rows[pid] = {'parent': int(fields[1]), 'start': fields[19], 'name': name, 'state': fields[0]}
    return descendants(rows, root, excluded)


def main():
    if sys.argv[1] == 'snapshot':
        print(json.dumps(snapshot(json.loads(RECORD.read_text())['pid'], [os.getpid()])))
        return 0
    # Linux subreapers retain ownership when a spawned child's parent exits.
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
    RECORD.write_text(json.dumps({'pid': os.getpid()}))
    statuses = {}
    def reap(_signal, _frame):
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return
            if pid == 0:
                return
            statuses[pid] = os.waitstatus_to_exitcode(status)
    signal.signal(signal.SIGCHLD, reap)
    child = subprocess.Popen(sys.argv[2:])
    code = child.wait()
    code = statuses.pop(child.pid, code)
    leaked = snapshot(os.getpid())
    if leaked:
        print('Shard OS process leaks: ' + json.dumps(leaked), flush=True)
        for identity in leaked:
            try:
                os.kill(int(identity.split(':')[1]), signal.SIGKILL)
            except ProcessLookupError:
                pass
        while True:
            try:
                os.waitpid(-1, 0)
            except ChildProcessError:
                break
        code = code or 1
    return code


if __name__ == '__main__':
    raise SystemExit(main())

"""Two Bee nodes on one host join one hive with a one-line invite.

Node A mints an invite, node B redeems it, and both supervisors hold an
established session over the mesh's identity TLS, each node on its own state
directory, identity and automatically selected ports. Both rejoin after
restarts without a new invite; a used or revoked invite is refused; when A
retires B, B's restarted owner is never admitted again.
"""
from pathlib import Path
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

INVITE = re.compile(r'^bee-hive://[0-9a-f]{32}:[0-9a-f]{64}@127\.0\.0\.1:(\d+)/(bee-owner-[0-9a-f]{16})\?key=[0-9a-f]{64}$')
ROOT = Path(__file__).resolve().parent.parent


class Nodes:
    def __init__(self, binary, root):
        self.binary = str(Path(binary).resolve())
        self.root = root
        self.home = root / 'home'
        self.project = root / 'project'
        self.home.mkdir()
        self.project.mkdir()

    def state(self, name):
        return self.root / name

    def bee(self, name, *arguments, check=True):
        environment = {key: value for key, value in os.environ.items() if not key.startswith('BEE_')}
        environment.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'))
        result = subprocess.run([self.binary, '--state', str(self.state(name)), 'hive', *arguments],
                                cwd=self.project, env=environment, capture_output=True, text=True, timeout=180)
        if check and result.returncode != 0:
            raise AssertionError(f'bee --state {name} hive {" ".join(arguments)} failed: {result.stdout}{result.stderr}')
        return result

    def peers(self, name):
        lines = self.bee(name, 'peers').stdout.splitlines()
        assert lines[0].startswith('NODE ') and lines[1].split() == ['PEER', 'SESSION'], lines
        return lines[0].split()[1], dict(line.split() for line in lines[2:])

    def owners(self, name):
        state = os.fsencode(str(self.state(name)))
        found = []
        for process in Path('/proc').iterdir():
            if not process.name.isdecimal():
                continue
            try:
                args = (process / 'cmdline').read_bytes().split(b'\0')
            except OSError:
                continue
            if args and args[0] == os.fsencode(self.binary) and state in args and b'start' in args:
                found.append(int(process.name))
        return found

    def stop(self, name):
        owners = self.owners(name)
        for owner in owners:
            os.kill(owner, signal.SIGTERM)
        deadline = time.monotonic() + 20
        while owners and time.monotonic() < deadline:
            owners = [owner for owner in owners if Path(f'/proc/{owner}').exists()]
            time.sleep(0.1)
        for owner in owners:
            os.kill(owner, signal.SIGKILL)
        assert not owners, f'owner of {name} ignored SIGTERM'

    def descriptor(self, name):
        return json.loads((self.state(name) / 'local-mesh' / 'mesh-owner.json').read_text())

    def session(self, name, peer, want, seconds):
        deadline = time.monotonic() + seconds
        seen = None
        while time.monotonic() < deadline:
            _, sessions = self.peers(name)
            seen = sessions.get(peer)
            if seen == want:
                return
            time.sleep(0.5)
        raise AssertionError(f'{name} session with {peer} is {seen}, want {want}')


def run(binary):
    scratch = ROOT / '.wippy'
    scratch.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='hive-join-', dir=scratch))
    nodes = Nodes(binary, root)
    try:
        line = nodes.bee('a', 'invite').stdout
        assert line.endswith('\n') and line.count('\n') == 1, repr(line)
        match = INVITE.match(line.strip())
        assert match, f'invite is not one pasteable line: {line!r}'
        node_a = match.group(2)
        a = nodes.descriptor('a')
        assert a['node'] == node_a and a['join'] == f'127.0.0.1:{match.group(1)}', a

        joined = nodes.bee('b', 'join', line.strip()).stdout.strip()
        node_b = joined.rsplit(' ', 1)[-1]
        assert joined == f'Joined the hive of {node_a} as {node_b}', joined
        b = nodes.descriptor('b')
        ports_a = {a['gossip'], a['transport'], a['join']}
        ports_b = {b['gossip'], b['transport'], b['join']}
        assert len(ports_a | ports_b) == 6, f'nodes share a port: {ports_a} {ports_b}'

        assert nodes.peers('a') == (node_a, {node_b: 'established'}), nodes.peers('a')
        assert nodes.peers('b') == (node_b, {node_a: 'established'}), nodes.peers('b')
        records = nodes.bee('a', 'invites').stdout.splitlines()[1:]
        assert len(records) == 1 and records[0].split()[1] == 'used' and records[0].split()[3] == node_b, records

        used = nodes.bee('c', 'join', line.strip(), check=False)
        assert used.returncode != 0 and 'invite was already used' in used.stderr, used
        revoked_line = nodes.bee('a', 'invite').stdout.strip()
        assert INVITE.match(revoked_line), revoked_line
        revoked_id = revoked_line.split('//')[1].split(':')[0]
        assert nodes.bee('a', 'revoke', revoked_id).stdout.strip() == f'Invite {revoked_id} revoked'
        revoked = nodes.bee('c', 'join', revoked_line, check=False)
        assert revoked.returncode != 0 and 'invite was revoked' in revoked.stderr, revoked

        # Each node keeps its gossip address across boots, so a restart of
        # either side finds the other where it was.
        for name in ('b', 'a'):
            print(f'Restart {name}', flush=True)
            nodes.stop(name)
            nodes.session(name, node_b if name == 'a' else node_a, 'established', 30)
            nodes.session('b' if name == 'a' else 'a', node_a if name == 'a' else node_b, 'established', 30)
        assert nodes.descriptor('a')['gossip'] == a['gossip'] and nodes.descriptor('b')['gossip'] == b['gossip'], 'a restart moved a gossip address'

        assert nodes.bee('a', 'leave', node_b).stdout.strip() == f'Left {node_b}'
        deadline = time.monotonic() + 10
        while node_b in nodes.peers('a')[1] and time.monotonic() < deadline:
            time.sleep(0.5)
        assert node_b not in nodes.peers('a')[1], nodes.peers('a')
        nodes.stop('b')
        _, sessions = nodes.peers('b')
        assert sessions.get(node_a) != 'established', sessions
        time.sleep(10)
        _, sessions = nodes.peers('b')
        assert sessions.get(node_a) in ('none', 'pending'), f'a retired node was admitted again: {sessions}'
        assert node_b not in nodes.peers('a')[1], nodes.peers('a')
    finally:
        for name in ('a', 'b', 'c'):
            nodes.stop(name)
        shutil.rmtree(root)
    print('Hive join: invite, TLS join with auto-picked ports, established sessions, restart rejoin, used and revoked invites refused, retired peer refused')


if __name__ == '__main__':
    run(sys.argv[1])

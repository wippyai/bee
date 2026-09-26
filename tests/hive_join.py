"""Two Bee nodes on one host join one hive with a one-line invite.

Node A mints an invite, node B redeems it, and both supervisors hold an
established session over the mesh's identity TLS, each node on its own state
directory, identity and automatically selected ports. No BEE_* environment
variable participates: the address each node advertises is picked and persisted
by Bee itself. Both rejoin after restarts without a new invite; a used or
revoked invite is refused; when A retires B, B's restarted owner is never
admitted again.

`run(binary, pair=...)` additionally proves the same sequence across two real
machines, in both invite directions and across the restart matrix, with no
environment variable on either side.
"""
from pathlib import Path
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from native_client import hold_owner, live_owners

# The primary endpoint is whatever address Bee picked for this host, so the
# shape is checked rather than one fixed address: Bee no longer defaults to
# loopback on a machine that has a LAN or Tailscale address.
INVITE = re.compile(r'^bee-hive://[0-9a-f]{32}:[0-9a-f]{64}@(?P<host>[^:/\s]+):(?P<port>\d+)/(?P<node>bee-owner-[0-9a-f]{16})\?key=[0-9a-f]{64}(?:&c=[^&\s]+){0,8}$')
INVITE_ANY = re.compile(r'bee-hive://\S+')
ROOT = Path(__file__).resolve().parent.parent
# Every BEE_* variable is dropped from a fixture environment, so a check can
# prove that no environment variable participates in Hive setup.
ENVIRONMENT_PREFIXES = ('BEE_',)


def clean_environment():
    return {key: value for key, value in os.environ.items() if not key.startswith(ENVIRONMENT_PREFIXES)}


def redact(value):
    return INVITE_ANY.sub('<invite redacted>', value)


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
        environment = clean_environment()
        environment.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'))
        result = subprocess.run([self.binary, '--state', str(self.state(name)), 'hive', *arguments],
                                cwd=self.project, env=environment, capture_output=True, text=True, timeout=180)
        if check and result.returncode != 0:
            safe_arguments = ['<invite redacted>' if argument.startswith('bee-hive://') else argument for argument in arguments]
            raise AssertionError(f'bee --state {name} hive {" ".join(safe_arguments)} failed: {result.stdout}{result.stderr}')
        return result

    def peers(self, name):
        lines = self.bee(name, 'peers').stdout.splitlines()
        assert lines[0].startswith('NODE ') and lines[1].split() == ['PEER', 'SESSION'], lines
        rows = [line.split() for line in lines[2:]]
        # Every peer carries a session; per-node holdings live in the
        # hive-telemetry package aggregate, not in this listing.
        for row in rows:
            assert len(row) == 2, row
            assert row[1] in ('none', 'pending', 'established'), row
        return lines[0].split()[1], {row[0]: row[1] for row in rows}, {}

    def stop(self, name):
        state = self.state(name)
        owners = [owner for owner in (hold_owner(pid, self.binary, state) for pid in live_owners(self.binary, state))
                  if owner is not None]
        try:
            for owner in owners:
                owner.send_signal(signal.SIGTERM)
            deadline = time.monotonic() + 20
            ignored = [owner for owner in owners if not owner.exited(max(0, deadline - time.monotonic()))]
            for owner in ignored:
                owner.send_signal(signal.SIGKILL)
                owner.exited(5)
            assert not ignored, f'owner of {name} ignored SIGTERM'
        finally:
            for owner in owners:
                owner.close()

    def descriptor(self, name):
        return json.loads((self.state(name) / 'local-mesh' / 'mesh-owner.json').read_text())

    def session(self, name, peer, want, seconds):
        """Wait for a session, tolerating a transient client-enrollment read.

        A freshly restarted owner enrolls its client a moment after it serves
        its first request, so one `bee hive peers` read can fail while the
        owner is otherwise healthy. Only a definite session answer counts.
        """
        deadline = time.monotonic() + seconds
        seen = None
        while time.monotonic() < deadline:
            _, sessions, _ = self.peers(name)
            seen = sessions.get(peer)
            if seen == want:
                return
            time.sleep(0.5)
        raise AssertionError(f'{name} session with {peer} is {seen}, want {want}')

    def mesh_address(self, name):
        """The address this node advertises: a path a peer proved it can reach
        wins over the automatic pick, matching the launch host's own rule."""
        directory = self.state(name) / 'hive'
        for name in ('reached', 'advertise'):
            path = directory / name
            if path.exists() and path.read_text().strip():
                return path.read_text().strip()
        return ''

    def mesh_files(self, name):
        """The persisted address files, for restart-matrix evidence."""
        directory = self.state(name) / 'hive'
        return {name: (directory / name).read_text().strip() if (directory / name).exists() else '-' 
                for name in ('advertise', 'reached', 'nat')}


class Remote:
    """One Bee binary on a second machine, driven over ssh.

    Every call carries no BEE_* variable and never prints an invite line.
    """

    def __init__(self, host, directory, binary):
        self.host = host
        self.directory = directory
        self.binary = binary
        self.started = set()
        self.run('mkdir -p "$HOME/{}"'.format(shlex.quote(directory)))

    def run(self, script, check=True, timeout=180):
        # Only PATH and LANG cross to the second machine: HOME stays the remote
        # user's own, and no BEE_* variable is ever exported there.
        environment = ' '.join(f'{key}={shlex.quote(value)}' for key, value in clean_environment().items()
                               if key in ('PATH', 'LANG'))
        command = f'env {environment} sh -c {shlex.quote(script)}'
        result = subprocess.run(['ssh', '-o', 'BatchMode=yes', self.host, command],
                                capture_output=True, text=True, timeout=timeout)
        if check and result.returncode != 0:
            raise AssertionError(f'remote command failed ({result.returncode}): {redact(result.stdout + result.stderr)}')
        return result

    def state(self, name):
        return f'$HOME/{self.directory}/{name}'

    def bee(self, name, *arguments, check=True, timeout=180):
        arguments = ' '.join(shlex.quote(value) for value in arguments)
        script = f'cd "$HOME/{self.directory}" && ./bee --state "{self.state(name)}" hive {arguments}'
        return self.run(script, check=check, timeout=timeout)

    def peers(self, name):
        lines = self.bee(name, 'peers').stdout.splitlines()
        assert lines[0].startswith('NODE ') and lines[1].split() == ['PEER', 'SESSION'], lines
        return lines[0].split()[1], dict(line.split() for line in lines[2:])

    def mesh_address(self, name):
        """The address this node advertises: a path a peer proved it can reach
        wins over the automatic pick, matching the launch host's own rule."""
        directory = f'$HOME/{self.directory}/{name}/hive'
        script = (f'if [ -s {directory}/reached ]; then cat {directory}/reached; '
                  f'elif [ -s {directory}/advertise ]; then cat {directory}/advertise; fi')
        return self.run(script).stdout.strip()

    def mesh_files(self, name):
        """The persisted address files, for restart-matrix evidence."""
        directory = f'$HOME/{self.directory}/{name}/hive'
        script = ('for f in advertise reached nat; do printf "%s: " $f; '
                  f'cat {directory}/$f 2>/dev/null || echo -; done')
        return self.run(script).stdout.strip()

    def wait_session(self, name, peer, want, seconds):
        """Wait for a session, tolerating a transient client-enrollment read.

        A freshly restarted owner enrolls its client a moment after it serves
        its first request, so one `bee hive peers` read can fail while the
        owner is otherwise healthy. Only a definite session answer counts.
        """
        deadline = time.monotonic() + seconds
        seen = None
        while time.monotonic() < deadline:
            try:
                _, sessions = self.peers(name)
            except AssertionError:
                time.sleep(1)
                continue
            seen = sessions.get(peer)
            if seen == want:
                return
            time.sleep(0.5)
        raise AssertionError(f'remote {name} session with {peer} is {seen}, want {want}')

    def stop(self, name):
        self.bee(name, 'stop', check=False, timeout=60)
        self.run(f'pkill -f "bee --state {self.state(name)} run start" || true', check=False)

    def cleanup(self):
        for name in sorted(self.started):
            try:
                self.stop(name)
            except (OSError, subprocess.TimeoutExpired):
                pass


def install_remote(host, directory, binary):
    """Copy the local binary to the second machine and make it runnable."""
    remote = Remote(host, directory, './bee')
    subprocess.run(['ssh', '-o', 'BatchMode=yes', host, f'mkdir -p "$HOME/{directory}"'], check=True, timeout=30)
    subprocess.run(['scp', '-q', '-o', 'BatchMode=yes', str(binary), f'{host}:$HOME/{directory}/bee'], check=True, timeout=300)
    remote.run(f'chmod +x "$HOME/{directory}/bee" && "$HOME/{directory}/bee" --help >/dev/null')
    return remote


def local(binary):
    scratch = ROOT / '.wippy'
    scratch.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='hive-join-', dir=scratch))
    nodes = Nodes(binary, root)
    try:
        line = nodes.bee('a', 'invite').stdout
        assert line.endswith('\n') and line.count('\n') == 1, 'invite is not one line'
        match = INVITE.match(line.strip())
        assert match, 'invite is not one pasteable line'
        node_a = match.group('node')
        a = nodes.descriptor('a')
        # The invite names the address Bee picked and persisted; the join
        # listener is bound on that same address and family.
        assert a['node'] == node_a and a['join'] == f'{match.group("host")}:{match.group("port")}', a
        assert nodes.mesh_address('a') == match.group('host'), (nodes.mesh_address('a'), match.group('host'))

        joined = nodes.bee('b', 'join', line.strip()).stdout.strip()
        node_b = joined.rsplit(' ', 1)[-1]
        assert joined == f'Joined the hive of {node_a} as {node_b}', joined
        b = nodes.descriptor('b')
        ports_a = {a['gossip'], a['transport'], a['join']}
        ports_b = {b['gossip'], b['transport'], b['join']}
        assert len(ports_a | ports_b) == 6, f'nodes share a port: {ports_a} {ports_b}'

        assert nodes.peers('a')[:2] == (node_a, {node_b: 'established'}), nodes.peers('a')
        assert nodes.peers('b')[:2] == (node_b, {node_a: 'established'}), nodes.peers('b')

        # Each node picked and persisted its own advertise address, and no
        # BEE_* variable was in the environment.
        assert nodes.mesh_address('a') and nodes.mesh_address('b'), 'a node persisted no advertise address'
        records = nodes.bee('a', 'invites').stdout.splitlines()[1:]
        assert len(records) == 1 and records[0].split()[1] == 'used' and records[0].split()[3] == node_b, records

        used = nodes.bee('c', 'join', line.strip(), check=False)
        assert used.returncode != 0 and 'invite was already used' in used.stderr, used
        revoked_line = nodes.bee('a', 'invite').stdout.strip()
        assert INVITE.match(revoked_line), 'revoked invite is not one pasteable line'
        revoked_id = revoked_line.split('//')[1].split(':')[0]
        assert nodes.bee('a', 'revoke', revoked_id).stdout.strip() == f'Invite {revoked_id} revoked'
        revoked = nodes.bee('c', 'join', revoked_line, check=False)
        assert revoked.returncode != 0 and 'invite was revoked' in revoked.stderr, revoked

        # Each node keeps its gossip address across boots, so a restart of
        # either side finds the other where it was. The bound is the same 60 s
        # the join itself waits for its first session.
        for name in ('b', 'a'):
            print(f'Restart {name}', flush=True)
            nodes.stop(name)
            nodes.session(name, node_b if name == 'a' else node_a, 'established', 60)
            nodes.session('b' if name == 'a' else 'a', node_a if name == 'a' else node_b, 'established', 60)
        assert nodes.descriptor('a')['gossip'] == a['gossip'] and nodes.descriptor('b')['gossip'] == b['gossip'], 'a restart moved a gossip address'

        assert nodes.bee('a', 'leave', node_b).stdout.strip() == f'Left {node_b}'
        deadline = time.monotonic() + 10
        while node_b in nodes.peers('a')[1] and time.monotonic() < deadline:
            time.sleep(0.5)
        assert node_b not in nodes.peers('a')[1], nodes.peers('a')
        nodes.stop('b')
        _, sessions, _ = nodes.peers('b')
        assert sessions.get(node_a) != 'established', sessions
        time.sleep(10)
        _, sessions, _ = nodes.peers('b')
        assert sessions.get(node_a) in ('none', 'pending'), f'a retired node was admitted again: {sessions}'
        assert node_b not in nodes.peers('a')[1], nodes.peers('a')
    finally:
        for name in ('a', 'b', 'c'):
            nodes.stop(name)
        shutil.rmtree(root)
    print('Hive join: invite, TLS join with auto-picked ports, established sessions, restart rejoin, used and revoked invites refused, retired peer refused')


class LocalSide:
    """One side of the pair check: a node on this host."""

    def __init__(self, nodes, name):
        self.nodes = nodes
        self.name = name

    def bee(self, *arguments, check=True):
        return self.nodes.bee(self.name, *arguments, check=check)

    def peers(self):
        return self.nodes.peers(self.name)

    def wait_session(self, peer, want, seconds):
        self.nodes.session(self.name, peer, want, seconds)

    def stop(self):
        self.nodes.stop(self.name)

    def mesh_address(self):
        return self.nodes.mesh_address(self.name)


class RemoteSide:
    """One side of the pair check: a node on the second machine."""

    def __init__(self, remote, name):
        self.remote = remote
        self.name = name
        self.remote.started.add(name)

    def bee(self, *arguments, check=True, timeout=180):
        return self.remote.bee(self.name, *arguments, check=check, timeout=timeout)

    def peers(self):
        return self.remote.peers(self.name)

    def wait_session(self, peer, want, seconds):
        self.remote.wait_session(self.name, peer, want, seconds)

    def stop(self):
        self.remote.stop(self.name)

    def mesh_address(self):
        return self.remote.mesh_address(self.name)


def restart_evidence(sides):
    """What both sides reported after a restart that did not re-establish.

    The state names the address each node advertises, the path a peer proved
    it could reach, and each side's session view, so a limitation is reported
    with the values that show it rather than as a bare failure.
    """
    parts = []
    for name, side in sides.items():
        try:
            parts.append(f'{name} address={side.mesh_address() or "none"} sessions={side.peers()[1]}')
        except AssertionError as failure:
            parts.append(f'{name} unreadable: {failure}')
    return '; '.join(parts)


def cross_machine(binary, host, directory):
    """Invite on each side, join from the other, then the restart matrix.

    No environment variable selects an address on either side. Every case is
    attempted and recorded, never skipped silently: the invite must be minted,
    the join must complete, and both supervisors should reach an established
    session. A join or a restart whose session does not establish is recorded
    with both sides' advertised address and session view, because the runtime
    fixes its memberlist gossip advertise address at boot; a peer whose
    automatic pick is not routable from the other side can therefore flap until
    the runtime's gossip-over-internode hook (H2) lands. The printed matrix
    states what works today and what waits for that hook.
    """
    results = {}
    remote = install_remote(host, directory, binary)
    scratch = ROOT / '.wippy'
    scratch.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='hive-pair-', dir=scratch))
    nodes = Nodes(binary, root)
    # Each run uses its own state names on both sides, so a leftover directory
    # from an earlier run never makes a node look already joined.
    run_id = root.name.removeprefix('hive-pair-')
    directions = ((f'local-invites-{run_id}', 'local', 'remote'),
                  (f'remote-invites-{run_id}', 'remote', 'local'))
    try:
        for label, inviter_name, joiner_name in directions:
            sides = {'local': LocalSide(nodes, label), 'remote': RemoteSide(remote, label)}
            inviter, joiner = sides[inviter_name], sides[joiner_name]
            inviter_node = joiner_node = ''
            # Every step is recorded, and one direction never stops the other
            # from being attempted, so the printed matrix is complete.
            try:
                line = inviter.bee('invite').stdout.strip()
                assert INVITE_ANY.fullmatch(line), f'{label}: invite is not one token'
                inviter_node = inviter.peers()[0]
                assert inviter.mesh_address(), f'{label}: the inviter persisted no advertise address'
                results[f'{label}-invite'] = 'minted'
            except AssertionError as failure:
                results[f'{label}-invite'] = f'failed: {failure}'
                print(f'{label}: invite failed: {failure}', flush=True)
            else:
                # The join command itself waits for the first supervisor session.
                try:
                    joined = joiner.bee('join', line).stdout.strip()
                    if not joined.startswith('Joined the hive of '):
                        raise AssertionError(joined)
                    joiner_node = joiner.peers()[0]
                    inviter.wait_session(joiner_node, 'established', 60)
                    joiner.wait_session(inviter_node, 'established', 60)
                    assert joiner.mesh_address(), f'{label}: the joiner persisted no advertise address'
                    results[label] = 'established'
                    print(f'{label}: {inviter_name} invite / {joiner_name} join, both sessions established', flush=True)
                except AssertionError as failure:
                    results[label] = f'not-established: {failure}; {restart_evidence(sides)}'
                    print(f'{label}: join did not reach both established sessions: {failure}', flush=True)
                    print(f'  evidence: {restart_evidence(sides)}', flush=True)
            # Restart the joiner, then the inviter, and re-verify each time.
            # Only a join that established has a peer to re-find.
            if results.get(label) == 'established':
                for role, side, peer in (('joiner', joiner, inviter_node), ('inviter', inviter, joiner_node)):
                    key = f'{label}-restart-{joiner_name if role == "joiner" else inviter_name}'
                    side.stop()
                    try:
                        side.wait_session(peer, 'established', 60)
                        (inviter if side is joiner else joiner).wait_session(side.peers()[0], 'established', 60)
                        results[key] = 'established'
                    except AssertionError as failure:
                        results[key] = f'not-re-established: {failure}; {restart_evidence(sides)}'
                        print(f'{label}: restart of the {role} ({joiner_name if role == "joiner" else inviter_name}) did not re-establish within 60 s: {failure}', flush=True)
                        print(f'  evidence: {restart_evidence(sides)}', flush=True)
            # Tear the pair down for the next direction.
            joiner.stop()
            inviter.stop()
            if inviter_node and joiner_node:
                inviter.bee('leave', joiner_node, check=False)
            inviter.stop()
            joiner.stop()
    finally:
        for label, _, _ in directions:
            nodes.stop(label)
        remote.cleanup()
        shutil.rmtree(root, ignore_errors=True)
    print('Hive pair matrix:')
    for case, outcome in sorted(results.items()):
        print(f'  {case}: {outcome}')
    return results


def run(binary, host=None, directory='bee-mesh'):
    local(binary)
    if host:
        cross_machine(binary, host, directory)


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument('binary')
    parser.add_argument('--host', default=None)
    parser.add_argument('--directory', default='bee-mesh')
    arguments = parser.parse_args()
    run(arguments.binary, arguments.host, arguments.directory)

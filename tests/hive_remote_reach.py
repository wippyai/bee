"""Opt-in two-machine Hive check. Never emits invite lines or invite secrets."""

import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time


INVITE = re.compile(r"bee-hive://[^\s]+")
ROOT = Path(__file__).resolve().parent.parent


def redact(value):
    return INVITE.sub("<invite redacted>", value)


class Pair:
    def __init__(self, host, local_ip, remote_ip):
        self.host = host
        self.local_ip = local_ip
        self.remote_ip = remote_ip
        self.local_root = Path(tempfile.mkdtemp(prefix="hive-remote-", dir=ROOT / ".wippy"))
        command = 'mktemp -d "$HOME/bee-reach/hive-remote-XXXXXX"'
        result = subprocess.run(["ssh", "-o", "BatchMode=yes", host, command], capture_output=True, text=True, timeout=15, check=True)
        self.remote_root = result.stdout.strip()
        if not self.remote_root.startswith("/home/") or "/bee-reach/hive-remote-" not in self.remote_root:
            raise RuntimeError("unexpected remote test state path")

    def call(self, side, name, *args, check=True, timeout=180):
        if side == "local":
            state = str(self.local_root / name)
            environment = os.environ.copy()
            environment["BEE_MESH_ADDRESS"] = self.local_ip
            command = [str(ROOT / "dist/bee"), "--state", state, *args]
            result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True, timeout=timeout)
        else:
            state = self.remote_root + "/" + name
            arguments = ["./bee", "--state", state, *args]
            command = "cd \"$HOME/bee-reach\" && env BEE_MESH_ADDRESS=" + shlex.quote(self.remote_ip) + " " + " ".join(shlex.quote(value) for value in arguments)
            result = subprocess.run(["ssh", "-o", "BatchMode=yes", self.host, command], capture_output=True, text=True, timeout=timeout)
        if check and result.returncode:
            safe = ["<invite redacted>" if value.startswith("bee-hive://") else value for value in args]
            raise RuntimeError(f"{side} {name} {' '.join(safe)} failed ({result.returncode}): {redact(result.stdout + result.stderr)}")
        return result

    def peers(self, side, name):
        lines = self.call(side, name, "hive", "peers").stdout.splitlines()
        if len(lines) < 2 or not lines[0].startswith("NODE "):
            raise RuntimeError(f"invalid {side} peer display")
        return lines[0].split()[1], {parts[0]: parts[1] for line in lines[2:] if len(parts := line.split()) >= 2}

    def wait_peers(self, side, name, peer):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            _, peers = self.peers(side, name)
            if peers.get(peer) == "established":
                return
            time.sleep(1)
        raise RuntimeError(f"{side} {name} did not establish its peer session")

    def direction(self, inviter):
        joiner = "remote" if inviter == "local" else "local"
        name = "from-wsl" if inviter == "local" else "from-remote"
        invite = self.call(inviter, name, "hive", "invite").stdout.strip()
        if not INVITE.fullmatch(invite):
            raise RuntimeError("invite command did not return exactly one token")
        inviter_node, _ = self.peers(inviter, name)
        joined = self.call(joiner, name, "hive", "join", invite).stdout.strip()
        if not joined.startswith("Joined the hive of "):
            raise RuntimeError("join command did not report an established session")
        joiner_node, _ = self.peers(joiner, name)
        self.wait_peers(inviter, name, joiner_node)
        self.wait_peers(joiner, name, inviter_node)
        print(f"{inviter} invite / {joiner} join: both supervisor sessions established", flush=True)

    def cleanup(self):
        for side in ("local", "remote"):
            for name in ("from-wsl", "from-remote"):
                try:
                    self.call(side, name, "stop", check=False, timeout=30)
                except (OSError, subprocess.TimeoutExpired):
                    pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--local-ip", required=True)
    parser.add_argument("--remote-ip", required=True)
    args = parser.parse_args()
    pair = Pair(args.host, args.local_ip, args.remote_ip)
    try:
        pair.direction("local")
        pair.direction("remote")
    finally:
        pair.cleanup()


if __name__ == "__main__":
    main()

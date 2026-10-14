# SPDX-License-Identifier: MIT
"""Run a command while holding the composed test workspace lock.

Usage: locked.py exclusive|shared LOCKFILE COMMAND [ARG...]
"""
import fcntl
import subprocess
import sys


def main() -> int:
    mode, path, command = sys.argv[1], sys.argv[2], sys.argv[3:]
    if mode not in ("exclusive", "shared") or not command:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if mode == "exclusive" else fcntl.LOCK_SH)
        return subprocess.call(command)


if __name__ == "__main__":
    sys.exit(main())

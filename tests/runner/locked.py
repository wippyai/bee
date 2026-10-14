# SPDX-License-Identifier: MIT
"""Run a command while holding the composed test workspace lock.

Usage: python3 -m tests.runner.locked [--cwd DIR] exclusive|shared LOCKFILE COMMAND [ARG...]
"""
import argparse
import fcntl
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cwd', default=None)
    parser.add_argument('mode', choices=('exclusive', 'shared'))
    parser.add_argument('path')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error('a command is required')
    with open(args.path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if args.mode == "exclusive" else fcntl.LOCK_SH)
        return subprocess.call(args.command, cwd=args.cwd)


if __name__ == "__main__":
    sys.exit(main())

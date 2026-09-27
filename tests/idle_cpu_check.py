#!/usr/bin/env python3
"""Measure a real standalone Bee owner while it is idle."""

import os
import pathlib
import select
import subprocess
import tempfile
import time


SAMPLE_SECONDS = 60
DEFAULT_LIMIT_PERCENT = 8.0


def cpu_ticks(pid: int) -> int:
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[13]) + int(fields[14])


def main() -> int:
    binary = pathlib.Path(os.environ.get("BEE_BINARY", "dist/bee")).resolve()
    if not binary.is_file():
        raise SystemExit(f"standalone Bee binary not found: {binary}")
    limit = float(os.environ.get("BEE_IDLE_CPU_LIMIT_PERCENT", DEFAULT_LIMIT_PERCENT))
    with tempfile.TemporaryDirectory(prefix="bee-idle-cpu-") as scratch:
        state = pathlib.Path(scratch, "state")
        owner = subprocess.Popen(
            [str(binary), "--state", str(state), "daemon"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            ready = False
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                readable, _, _ = select.select([owner.stdout], [], [], 1)
                if not readable:
                    if owner.poll() is not None:
                        break
                    continue
                line = owner.stdout.readline()
                if not line:
                    break
                if line.startswith("BEE_DAEMON_READY "):
                    ready = True
                    break
            if not ready:
                raise RuntimeError("standalone Bee owner did not become ready")

            ticks_per_second = os.sysconf("SC_CLK_TCK")
            before_ticks = cpu_ticks(owner.pid)
            started = time.monotonic()
            time.sleep(SAMPLE_SECONDS)
            elapsed = time.monotonic() - started
            used = (cpu_ticks(owner.pid) - before_ticks) / ticks_per_second
            percent = used / elapsed * 100
            print(f"idle owner CPU: {percent:.2f}% ({used:.2f}s / {elapsed:.2f}s)")
            if percent > limit:
                raise RuntimeError(f"idle owner CPU {percent:.2f}% exceeds {limit:.2f}%")
            return 0
        finally:
            if owner.poll() is None:
                owner.terminate()
                try:
                    owner.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    owner.kill()
                    owner.wait()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as failure:
        raise SystemExit(str(failure)) from failure

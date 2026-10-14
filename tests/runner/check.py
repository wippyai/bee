"""Run Bee's verification gate with one final status and timing line."""
import os
from pathlib import Path
import subprocess
import time


def check():
    started = time.monotonic()
    initial_load = os.getloadavg()[0]
    targets = ("lint", "fixture-lint", "boot-check", "test")
    code = subprocess.call(["make", "--no-print-directory", "-j1", *targets, "TESTS="],
                           cwd=Path(__file__).resolve().parents[2])
    elapsed = time.monotonic() - started
    print(f"CHECK {'FAILED' if code else 'PASSED'}: lint + fixture-lint + boot + suites; "
          f"{elapsed:.2f}s; load {initial_load:.2f} -> {os.getloadavg()[0]:.2f}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(check())

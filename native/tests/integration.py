#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the native module through the real Wippy scheduler and permissions."""
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

runtime = Path(sys.argv[1]).resolve()
fixture = Path(__file__).resolve().parent / "fixture"
with tempfile.TemporaryDirectory(prefix="bee-ioevents-") as temporary:
    workspace = Path(temporary) / "application"
    shutil.copytree(fixture, workspace)
    root = Path(temporary) / "watched files"
    root.mkdir()
    env = {**os.environ, "BEE_IOEVENTS_TEST_ROOT": str(root)}
    subprocess.run([str(runtime), "lint", "--silent"], cwd=workspace, env=env, check=True, timeout=30)
    denied = subprocess.run([str(runtime), "run", "--silent", "denied"], cwd=workspace, env=env, text=True, capture_output=True, timeout=15)
    if denied.returncode or "DENIED" not in denied.stdout or "not permitted" not in denied.stdout:
        raise SystemExit(f"Permission denial failed: {denied.stdout}\n{denied.stderr}")
    process = subprocess.Popen([str(runtime), "run", "--silent", "watch"], cwd=workspace, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    created = False
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and process.poll() is None:
            for key, _ in selector.select(0.2):
                chunk = os.read(key.fd, 65536)
                if chunk:
                    output.extend(chunk)
                if b"READY" in output and not created:
                    (root / "changed.txt").write_text("native change\n")
                    created = True
        if process.poll() is None:
            raise SystemExit(f"Watcher timed out: {output.decode(errors='replace')}")
        output.extend(process.stdout.read())
        if process.returncode or b"CHANGED" not in output:
            raise SystemExit(f"Watcher failed: {output.decode(errors='replace')}")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
print("Native module typing, permission denial and scheduler event delivery passed")

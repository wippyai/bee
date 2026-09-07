#!/usr/bin/env python3
"""Build the reviewed runtime from a pinned commit plus a checked patch.

BEE_RUNTIME_REPOSITORY may name a local Git clone for offline development.
Its working tree is never used or changed. Build output replaces the old binary
only after a successful build; no local application state is touched.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
lock = json.loads((ROOT / "runtime/lock.json").read_text())
patch = ROOT / "runtime" / lock["patch"]
assert hashlib.sha256(patch.read_bytes()).hexdigest() == lock["patch_sha256"], "Runtime patch checksum mismatch"
repository = os.environ.get("BEE_RUNTIME_REPOSITORY", lock["repository"])
output = ROOT / ".wippy/bin"
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="bee-runtime-") as temporary:
    source = Path(temporary) / "source"
    subprocess.run(["git", "clone", "--no-checkout", "--filter=blob:none", repository, str(source)], check=True)
    subprocess.run(["git", "checkout", "--detach", lock["commit"]], cwd=source, check=True)
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=source, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=source, check=True)
    env = {**os.environ, "CGO_ENABLED": "1", "GOWORK": "off", "GOTOOLCHAIN": "go" + lock["go"]}
    binary = Path(temporary) / "wippy"
    subprocess.run(["go", "build", "-trimpath", "-tags", lock["tags"], "-o", str(binary), "./cmd/wippy"], cwd=source, env=env, check=True)
    staging = output / "wippy.next"
    shutil.copy2(binary, staging)
    staging.replace(output / "wippy")
    (output / "provenance.json").write_text(json.dumps(lock, indent=2) + "\n")
print("Runtime ready: .wippy/bin/wippy")

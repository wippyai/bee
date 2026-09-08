#!/usr/bin/env python3
"""Invoke the pinned application builder from a clean private Git checkout."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
lock = json.loads((ROOT / "runtime/builder.lock.json").read_text())
cache = ROOT / ".wippy/tools/builder"
cache.mkdir(parents=True, exist_ok=True)
checkout = cache / lock["commit"]
if not checkout.exists():
    with tempfile.TemporaryDirectory(prefix="fetch-", dir=cache) as temporary:
        source = Path(temporary) / "source"
        repository = os.environ.get("BEE_BUILDER_REPOSITORY", lock["repository"])
        subprocess.run(["git", "clone", "--no-checkout", repository, str(source)], check=True)
        subprocess.run(["git", "checkout", "--detach", lock["commit"]], cwd=source, check=True)
        source.rename(checkout)
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=checkout, text=True)
if commit != lock["commit"] or status:
    raise SystemExit("Pinned builder checkout was modified")
subprocess.run([sys.executable, str(checkout / "builder.py"), *sys.argv[1:]], check=True)

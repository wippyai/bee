#!/usr/bin/env python3
"""Stage an isolated Wippy fixture; no production registration or dependencies."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()

def stage(folder):
    project = Path(folder)
    shutil.copytree(Path(__file__).parent / "src", project / "src")
    # Exercise the actual current production model, not a second test implementation.
    shutil.copy2(ROOT / "src/core/desktop/model.lua", project / "src/model.lua")
    (project / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
    (project / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
    return project

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("thread", nargs="?", default="local-tests")
    parser.add_argument("--run", default=str(uuid.uuid4()), help="stable retry identity; default creates a new run")
    parser.add_argument("--after", type=int, default=0, help="resume after this committed event sequence")
    parser.add_argument("--db", type=Path, default=ROOT / ".wippy/thread-demo.db")
    args = parser.parse_args()
    database = args.db.resolve()
    database.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-thread-demo-") as folder:
        project = stage(folder)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        result = subprocess.run([str(RUNTIME), "run", "thread-demo", "--", args.thread, args.run, str(args.after)],
                                cwd=project, env={**os.environ, "BEE_THREAD_DEMO_DB": str(database)})
        raise SystemExit(result.returncode)

if __name__ == "__main__":
    main()

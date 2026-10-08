#!/usr/bin/env python3
"""Build the isolated Hive e2e pack with its host fixture."""
from pathlib import Path
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".wippy" / "e2e-build"

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "src", OUT / "src", dirs_exist_ok=True)
    shutil.copytree(ROOT / "tests" / "fixtures" / "hive", OUT / "src" / "e2e_hive", dirs_exist_ok=True)
    for name in ("wippy.yaml", "wippy.lock", ".wippy.yaml"):
        shutil.copyfile(ROOT / name, OUT / name)
    (OUT / ".wippy").mkdir(exist_ok=True)
    vendor = OUT / ".wippy" / "vendor"
    if not vendor.exists():
        vendor.symlink_to(ROOT / ".wippy" / "vendor", target_is_directory=True)
    manifest = json.loads((ROOT / "wippy.build.json").read_text())
    manifest["application"]["packs"][0]["path"] = "bee.wapp"
    target = OUT / "wippy.build.json"
    target.write_text(json.dumps(manifest, indent=2) + "\n")
    builder = ROOT / ".wippy" / "bin" / "wippy-builder"
    temporary = OUT / "temporary"
    temporary.mkdir(exist_ok=True)
    environment = dict(os.environ, TMPDIR=str(temporary))
    subprocess.run([str(builder), "pack", str(target), "--toolchain", str(ROOT / ".wippy" / "bin" / "wippy"),
                    "--version", manifest["application"]["packs"][0]["version"]], cwd=OUT, env=environment, check=True)
    subprocess.run([str(builder), "build", str(target), "-o", str(OUT / "bee")], cwd=OUT, env=environment, check=True)

if __name__ == "__main__":
    main()

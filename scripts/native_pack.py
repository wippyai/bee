#!/usr/bin/env python3
"""Pack Bee with its canonical module identity and seal the native build input."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
path = root / "wippy.build.json"
manifest = json.loads(path.read_text())
pack = next(item for item in manifest["application"]["packs"] if item["module"] == manifest["application"]["module"])
version = os.environ.get("BEE_VERSION", pack["version"]).removeprefix("v")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
    raise SystemExit("BEE_VERSION must be an exact application version")
output = root / pack["path"]
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.argv[1], "pack", str(output), "--meta", "namespace=bee.bee", "--meta", "name=bee", "--meta", "version="+version, "--silent"], cwd=root, check=True)
pack["version"] = version
pack["sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
path.write_text(json.dumps(manifest, indent=2)+"\n")

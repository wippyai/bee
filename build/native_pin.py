#!/usr/bin/env python3
"""Pin Bee's native module: write the Go pseudo-version of one Bee commit into
every native entry of wippy.build.json.

The release build fetches github.com/wippyai/bee/native at that version, so the
commit must be pushed and must contain the native packages the manifest names.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "wippy.build.json"


def pseudo_version(commit: str) -> str:
    stamp = subprocess.run(["git", "show", "-s", "--format=%cd", "--date=format-local:%Y%m%d%H%M%S", commit],
                           cwd=ROOT, check=True, capture_output=True, text=True, env={"TZ": "UTC", "PATH": "/usr/bin:/bin"}).stdout.strip()
    full = subprocess.run(["git", "rev-parse", commit], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    return f"v0.0.0-{stamp}-{full[:12]}"


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{7,40}", sys.argv[1]):
        print("usage: native_pin.py <bee commit>", file=sys.stderr)
        return 2
    version = pseudo_version(sys.argv[1])
    text = MANIFEST.read_text()
    manifest = json.loads(text)
    for entry in manifest["native"]:
        entry["version"] = version
    MANIFEST.write_text(json.dumps(manifest, indent=2) + ("\n" if text.endswith("\n") else ""))
    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Give the bee/bee module the version it is released as.

The packer takes a module's identity from its wippy.yaml, so a release writes
its version there and into the bee/bee pack entry of wippy.build.json before
`make build VERSION=<version>` packs and builds it.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APPLICATION = ROOT / "wippy.yaml"
MANIFEST = ROOT / "wippy.build.json"
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?")


def main() -> int:
    if len(sys.argv) != 2 or not SEMVER.fullmatch(sys.argv[1]):
        print("usage: release_version.py <semantic version>", file=sys.stderr)
        return 2
    version = sys.argv[1]
    text = APPLICATION.read_text()
    stamped, count = re.subn(r"(?m)^version: .*$", f"version: {version}", text, count=1)
    if count != 1:
        print("wippy.yaml declares no version", file=sys.stderr)
        return 1
    APPLICATION.write_text(stamped)
    manifest = json.loads(MANIFEST.read_text())
    packs = [pack for pack in manifest["application"]["packs"] if pack.get("module") == "bee/bee"]
    if len(packs) != 1:
        print("wippy.build.json has no single bee/bee pack", file=sys.stderr)
        return 1
    packs[0]["version"] = version
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())

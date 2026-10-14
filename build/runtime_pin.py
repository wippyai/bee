#!/usr/bin/env python3
"""Pin the release runtime: write RUNTIME_VERSION into wippy.build.json.

The native module's runtime requirement moves with it through `go get` in the
Makefile, so the packed application and the native host build against one
runtime commit.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "wippy.build.json"


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        print("usage: runtime_pin.py <40-character runtime commit>", file=sys.stderr)
        return 2
    text = MANIFEST.read_text()
    manifest = json.loads(text)
    manifest["runtime"]["version"] = sys.argv[1]
    MANIFEST.write_text(json.dumps(manifest, indent=2) + ("\n" if text.endswith("\n") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

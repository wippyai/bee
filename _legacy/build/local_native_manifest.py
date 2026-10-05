# SPDX-License-Identifier: MIT
"""Rewrite the build manifest to compile this worktree's native module.

Every native component is pinned to the local pseudo-version and its `private`
marker is dropped so Go resolves it through the development proxy instead of
direct VCS. The sealed release manifest is never changed.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: local_native_manifest SOURCE DEST VERSION", file=sys.stderr)
        return 2
    source, dest, version = sys.argv[1], sys.argv[2], sys.argv[3]
    if not version.startswith("v0.0.0-"):
        print("local native version must be a v0.0.0 pseudo-version", file=sys.stderr)
        return 2
    with open(source, encoding="utf-8") as handle:
        manifest = json.load(handle)
    native = manifest.get("native") or []
    if not native:
        print("manifest selects no native component", file=sys.stderr)
        return 2
    for component in native:
        component["version"] = version
        component.pop("private", None)
    with open(dest, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

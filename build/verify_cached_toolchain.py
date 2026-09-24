#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check a cached native toolchain against the pinned manifest and builder."""

import hashlib
import json
from pathlib import Path
import re
import stat
import sys


ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".wippy/bin/bee-wippy"
BUILDER = ROOT / ".wippy/bin/wippy-builder"
BUILDER_DIGEST = ROOT / ".wippy/bin/bee-wippy.builder.sha256"
ARTIFACTS = {
    "binary": BINARY,
    "licenses": Path(f"{BINARY}.LICENSES.txt"),
    "go.mod": Path(f"{BINARY}.go.mod"),
    "go.sum": Path(f"{BINARY}.go.sum"),
    "runtime-patches": Path(f"{BINARY}.runtime-patches.tar.gz"),
}


def digest(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"not a regular file: {path}")
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def selected_inputs(manifest, lock):
    # A toolchain build does not embed application packs, data or the app name.
    return {
        "runtime": manifest["runtime"],
        "native": manifest.get("native", []),
        "builder": lock["commit"],
    }


def check_action_pin(lock):
    workflow = (ROOT / ".github/workflows/native.yml").read_text()
    pins = re.findall(r"uses:\s*wippyai/builder@([0-9a-f]{40})", workflow)
    if not pins or set(pins) != {lock["commit"]}:
        raise ValueError("native workflow builder pin differs from build/builder.lock.json")


def keys():
    manifest = json.loads((ROOT / "wippy.build.json").read_text())
    lock = json.loads((ROOT / "build/builder.lock.json").read_text())
    check_action_pin(lock)
    inputs = json.dumps(selected_inputs(manifest, lock), sort_keys=True, separators=(",", ":"))
    print(f"toolchain={hashlib.sha256(inputs.encode()).hexdigest()}")
    print(f"runtime={manifest['runtime']['commit']}")


def verify(record):
    manifest = json.loads((ROOT / "wippy.build.json").read_text())
    lock = json.loads((ROOT / "build/builder.lock.json").read_text())
    check_action_pin(lock)
    provenance = json.loads(Path(f"{BINARY}.provenance.json").read_text())
    builder = provenance.get("builder", {})
    if provenance.get("schema") != 1 or provenance.get("mode") != "toolchain":
        raise ValueError("cached output is not a toolchain build")
    cached_manifest = provenance.get("manifest")
    if not isinstance(cached_manifest, dict) or (
        selected_inputs(cached_manifest, lock) != selected_inputs(manifest, lock)
    ):
        raise ValueError("cached toolchain inputs differ from wippy.build.json")
    if builder.get("revision") != lock["commit"] or builder.get("modified") is not False:
        raise ValueError("cached toolchain was not built by the pinned builder")
    if builder.get("go") != f"go{manifest['runtime']['go']}":
        raise ValueError("cached toolchain was built with a different Go version")
    expected = provenance.get("artifacts")
    if not isinstance(expected, dict) or expected.keys() != ARTIFACTS.keys():
        raise ValueError("cached toolchain has an incomplete artifact set")
    for name, path in ARTIFACTS.items():
        if digest(path) != expected[name]:
            raise ValueError(f"cached {name} does not match provenance")
    builder_digest = digest(BUILDER)
    if record:
        BUILDER_DIGEST.write_text(builder_digest + "\n")
    elif BUILDER_DIGEST.read_text().strip() != builder_digest:
        raise ValueError("cached builder does not match its recorded digest")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("keys", "record", "verify"):
        sys.exit("usage: verify_cached_toolchain.py keys|record|verify")
    try:
        if sys.argv[1] == "keys":
            keys()
        else:
            verify(sys.argv[1] == "record")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        sys.exit(f"cached toolchain verification failed: {error}")

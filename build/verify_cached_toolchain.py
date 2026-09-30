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


def binary_path(root):
    return root / ".wippy/bin/bee-wippy"


def artifacts(root):
    binary = binary_path(root)
    return {
        "binary": binary,
        "licenses": Path(f"{binary}.LICENSES.txt"),
        "go.mod": Path(f"{binary}.go.mod"),
        "go.sum": Path(f"{binary}.go.sum"),
        "runtime-patches": Path(f"{binary}.runtime-patches.tar.gz"),
    }


def builder_path(root):
    return root / ".wippy/bin/wippy-builder"


def builder_digest_path(root):
    return root / ".wippy/bin/bee-wippy.builder.sha256"


def provenance_path(root):
    return Path(f"{binary_path(root)}.provenance.json")


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


def check_action_pin(root, lock):
    workflow = (root / ".github/workflows/native.yml").read_text()
    pins = re.findall(r"uses:\s*wippyai/builder@([0-9a-f]{40})", workflow)
    if not pins or set(pins) != {lock["commit"]}:
        raise ValueError("native workflow builder pin differs from build/builder.lock.json")


def read_manifest(root):
    return json.loads((root / "wippy.build.json").read_text())


def read_lock(root):
    return json.loads((root / "build/builder.lock.json").read_text())


def keys(root=ROOT):
    manifest = read_manifest(root)
    lock = read_lock(root)
    check_action_pin(root, lock)
    inputs = json.dumps(selected_inputs(manifest, lock), sort_keys=True, separators=(",", ":"))
    print(f"toolchain={hashlib.sha256(inputs.encode()).hexdigest()}")
    print(f"runtime={manifest['runtime']['commit']}")


def check_current(root=ROOT):
    """Raise ValueError when the cached toolchain was not built from root's manifest."""
    manifest = read_manifest(root)
    lock = read_lock(root)
    try:
        provenance = json.loads(provenance_path(root).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cached toolchain has no readable provenance: {error}")
    cached_manifest = provenance.get("manifest")
    if not isinstance(cached_manifest, dict) or (
        selected_inputs(cached_manifest, lock) != selected_inputs(manifest, lock)
    ):
        raise ValueError("cached toolchain was built from a different manifest")


def verify(record, root=ROOT):
    manifest = read_manifest(root)
    lock = read_lock(root)
    check_action_pin(root, lock)
    provenance = json.loads(provenance_path(root).read_text())
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
    names = artifacts(root)
    if not isinstance(expected, dict) or expected.keys() != names.keys():
        raise ValueError("cached toolchain has an incomplete artifact set")
    for name, path in names.items():
        if digest(path) != expected[name]:
            raise ValueError(f"cached {name} does not match provenance")
    builder_digest = digest(builder_path(root))
    digest_path = builder_digest_path(root)
    if record:
        digest_path.write_text(builder_digest + "\n")
    elif digest_path.read_text().strip() != builder_digest:
        raise ValueError("cached builder does not match its recorded digest")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("keys", "record", "verify", "current"):
        sys.exit("usage: verify_cached_toolchain.py keys|record|verify|current")
    try:
        if sys.argv[1] == "keys":
            keys()
        elif sys.argv[1] == "current":
            check_current()
        else:
            verify(sys.argv[1] == "record")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        sys.exit(f"cached toolchain verification failed: {error}")

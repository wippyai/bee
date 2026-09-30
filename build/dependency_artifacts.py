#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Copy checksum-pinned upstream packs without rewriting their contents."""
import hashlib
from pathlib import Path
import shutil
import sys
import yaml


def copy_dependencies(lock_path, source_vendor, destination_vendor):
    for module in yaml.safe_load(Path(lock_path).read_text())["modules"]:
        organization, name = module["name"].split("/")
        if organization == "bee":
            continue
        expected = module.get("hash", "").removeprefix("sha256:")
        if len(expected) != 64:
            raise ValueError(f"unsealed upstream dependency: {module['name']}")
        filename = f"{name}-{module['version']}.wapp"
        candidates = [Path(source_vendor) / organization / filename,
                      Path(source_vendor) / organization / f"{name}-{module['version']}.sha256-{expected}.wapp"]
        source = next((path for path in candidates if path.is_file()), None)
        if source is None or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError(f"missing or changed upstream dependency: {module['name']}")
        destination = Path(destination_vendor) / organization / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


if __name__ == "__main__":
    copy_dependencies(*sys.argv[1:])

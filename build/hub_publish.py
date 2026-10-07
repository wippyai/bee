#!/usr/bin/env python3
"""Verify and publish the exact Bee pack attached to a GitHub release."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?")


def download(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def publish(version, wippy, directory):
    if not SEMVER.fullmatch(version):
        raise ValueError("VERSION must be a semantic version without the v prefix")
    name = f"bee-{version}.wapp"
    base = f"https://github.com/wippyai/bee/releases/download/v{version}"
    pack = download(f"{base}/{name}")
    checksum = download(f"{base}/{name}.sha256").decode("ascii").split()
    if (len(checksum) != 2 or checksum[1] != name or not re.fullmatch(r"[0-9a-f]{64}", checksum[0])
            or hashlib.sha256(pack).hexdigest() != checksum[0]):
        raise ValueError(f"release pack checksum does not match {name}")
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / name
    target.write_bytes(pack)
    subprocess.run([wippy, "publish", "--config", str(ROOT), "--wapp", str(target), "--version", version],
                   cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--wippy", required=True)
    args = parser.parse_args()
    publish(args.version, args.wippy, ROOT / ".wippy/hub-publish" / args.version)


if __name__ == "__main__":
    main()

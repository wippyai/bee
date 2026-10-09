#!/usr/bin/env python3
"""Write the Bee pack identity from the pinned toolchain's resolved modules."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
NATIVE = "github.com/wippyai/bee/native"


def generate(manifest, provenance, go_mod, version, revision):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?", version):
        raise ValueError("pack version must be a semantic version")
    recorded = provenance.get("manifest", {})
    if (provenance.get("schema") != 1 or provenance.get("mode") != "toolchain"
            or recorded.get("runtime") != manifest["runtime"]
            or recorded.get("native") != manifest["native"]):
        raise ValueError("toolchain provenance does not match the runtime and native pins")
    if hashlib.sha256(go_mod).hexdigest() != provenance["artifacts"]["go.mod"]:
        raise ValueError("resolved go.mod does not match toolchain provenance")
    scratch = ROOT / ".wippy/identity"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=scratch, suffix=".mod") as resolved:
        resolved.write(go_mod)
        resolved.flush()
        document = json.loads(subprocess.check_output(["go", "mod", "edit", "-json", resolved.name]))
    if document.get("Replace"):
        raise ValueError("module replacements do not provide a release binary identity")
    modules = {row["Path"]: row["Version"] for row in document.get("Require", [])}
    native = sorted({row["module"] for row in manifest["native"]})
    if NATIVE not in native or any(name not in modules for name in native + [manifest["runtime"]["module"]]):
        raise ValueError("toolchain does not resolve all pinned modules")
    return {"name": "binary_identity", "kind": "registry.entry", "meta": {"type": "bee.binary_identity"},
            "data": {"version": version, "build": revision, "source": "https://github.com/wippyai/bee",
                     "source_revision": revision, "runtime": "https://github.com/wippyai/runtime",
                     "runtime_commit": modules[manifest["runtime"]["module"]], "native": NATIVE,
                     "native_version": modules[NATIVE], "website": "https://bee.wippy.ai",
                     "native_components": [{"package": name, "version": modules[name]} for name in native]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "wippy.build.json")
    parser.add_argument("--toolchain", type=Path, default=ROOT / ".wippy/bin/wippy")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    provenance = json.loads(Path(str(args.toolchain) + ".provenance.json").read_text())
    go_mod = Path(str(args.toolchain) + ".go.mod").read_bytes()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    entry = generate(manifest, provenance, go_mod, args.version, revision)
    target = ROOT / "src/env/binary_identity/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    writer = {"name": "state_writer_version", "kind": "library.lua",
              "source": "return {version = " + json.dumps(args.version) + ", build = " + json.dumps(revision) + "}"}
    target.write_text(json.dumps({"version": "1.0", "namespace": "bee.env", "entries": [entry, writer]}, indent=2) + "\n")
    print(f"bee.binary_identity: runtime {entry['data']['runtime_commit']}, native {entry['data']['native_version']}")


if __name__ == "__main__":
    main()

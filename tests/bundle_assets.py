# SPDX-License-Identifier: MIT
"""Prove component assets travel inside packs, without a source filesystem."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build"))
from bundle import prepare

RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()
WASM = b"\x00asm\x01\x00\x00\x00"  # Valid empty module; this checks transfer, not execution.
PROBE = '''local fs = require("fs")
local io = require("io")
local function main()
    local volume, volume_error = fs.get("asset.probe:files")
    if not volume then error(tostring(volume_error)) end
    local data, read_error = volume:readfile("module.wasm")
    if read_error then error(tostring(read_error)) end
    assert(data == string.char(0, 97, 115, 109, 1, 0, 0, 0), "WASM bytes changed")
    local nested, nested_error = volume:readfile("templates/start.txt")
    assert(nested_error == nil and nested == "component template\\n", "nested asset missing")
    local wrote, write_error = volume:writefile("module.wasm", "changed")
    assert(not wrote and write_error ~= nil, "installed asset was writable")
    local retained, retained_error = volume:readfile("module.wasm")
    assert(retained_error == nil and retained == data, "rejected write changed bytes")
    io.print("Component assets: WASM and nested template retained; embedded filesystem is read-only")
end
return {main = main}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="bee-bundle-assets-") as temporary:
        folder = Path(temporary)
        source = folder / "project"
        (source / "src").mkdir(parents=True)
        assets = source / "assets" / "templates"
        assets.mkdir(parents=True)
        (assets.parent / "module.wasm").write_bytes(WASM)
        (assets / "start.txt").write_text("component template\n")
        (source / "wippy.yaml").write_text(yaml.safe_dump({"organization": "asset", "module": "probe",
            "license": "MIT", "embed": ["asset.probe:files"]}))
        (source / ".wippy.yaml").write_text("version: '1.0'\n")
        (source / "wippy.lock").write_text("directories: {modules: .wippy, src: ./src}\n")
        entries = [
            {"name": "definition", "kind": "ns.definition"},
            {"name": "files", "kind": "fs.directory", "directory": "./assets", "base": "module"},
            {"name": "workers", "kind": "process.host", "host": {"max_processes": 4, "workers": 2},
             "lifecycle": {"auto_start": True}},
            {"name": "terminal", "kind": "terminal.host", "lifecycle": {"auto_start": True}},
            {"name": "read_policy", "kind": "security.policy", "policy": {
                "actions": ["fs.get"], "resources": ["asset.probe:files"], "effect": "allow"}},
            {"name": "probe", "kind": "process.lua", "source": "file://probe.lua", "method": "main",
             "modules": ["fs", "io"], "meta": {"command": {"name": "asset-probe", "security": {
                 "actor": {"id": "asset-probe"}, "policies": ["asset.probe:read_policy"]}}}},
        ]
        (source / "src/_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "asset.probe", "entries": entries}))
        (source / "src/probe.lua").write_text(PROBE)
        manifest = source / "wippy.build.json"
        manifest.write_text(json.dumps({"runtime": {"patches": []}, "application": {
            "module": "asset/probe", "packs": [{"module": "asset/probe", "version": "0.1.0"}]}}))
        plan = source / "modules.json"
        plan.write_text(json.dumps({"schema": 1, "modules": [{"module": "asset/probe", "root": "asset.probe",
                                                             "namespaces": ["asset.probe"]}]}))
        output = folder / "bundle" / "manifest.json"
        prepare(source, manifest, plan, output, RUNTIME)
        artifact = json.loads(output.read_text())["application"]["packs"][0]
        packed = output.parent / artifact["path"]
        assert hashlib.sha256(packed.read_bytes()).hexdigest() == artifact["sha256"]
        installed = folder / "installed"
        installed.mkdir()
        shutil.copy2(packed, installed / "component.wapp")
        # Remove source, the build snapshot and all loose files before consumption.
        shutil.rmtree(source)
        shutil.rmtree(output.parent)
        result = subprocess.check_output([str(RUNTIME), "run", str(installed / "component.wapp"),
            "asset-probe", "--host", "asset.probe:terminal"], cwd=installed, stderr=subprocess.STDOUT, text=True)
        marker = "Component assets: WASM and nested template retained; embedded filesystem is read-only"
        assert marker in result, result
        print(marker)


if __name__ == "__main__":
    main()

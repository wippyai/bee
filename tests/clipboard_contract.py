# SPDX-License-Identifier: MIT
"""Run the pure clipboard boundary with Wippy's runner, without a desktop host."""
import shutil
import subprocess
import tempfile
from pathlib import Path

import yaml
from workspace import ROOT, RUNTIME


with tempfile.TemporaryDirectory(prefix="bee-clipboard-contract-") as temporary:
    folder = Path(temporary)
    source = folder / "src"
    source.mkdir()
    shutil.copy2(ROOT / "src/core/client/clipboard.lua", source)
    shutil.copy2(ROOT / "tests/lua/client/clipboard_test.lua", source)
    document = {
        "version": "1.0", "namespace": "bee.client", "entries": [
            {"name": "clipboard", "kind": "library.lua", "source": "file://clipboard.lua"},
            {"name": "clipboard_test", "kind": "function.lua", "source": "file://clipboard_test.lua",
             "method": "run", "meta": {"type": "test", "suite": "bee"},
             "imports": {"test": "wippy.test:test", "clipboard": "bee.client:clipboard"}},
            {"name": "test_dependency", "kind": "ns.dependency", "component": "wippy/test", "version": "0.4.17"},
            {"name": "terminal", "kind": "terminal.host", "lifecycle": {"auto_start": True}},
            {"name": "workers", "kind": "process.host", "host": {"workers": 2, "max_processes": 16}, "lifecycle": {"auto_start": True}},
        ],
    }
    (source / "_index.yaml").write_text(yaml.safe_dump(document, sort_keys=False))
    (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
    (folder / ".wippy.yaml").write_text("version: '1.0'\nlua:\n  type_system:\n    enabled: true\n    strict: true\n")
    vendor = folder / ".wippy/vendor/wippy"
    vendor.mkdir(parents=True)
    packages = list((ROOT / ".wippy/vendor/wippy").glob("test-0.4.17*.wapp"))
    if not packages:
        raise RuntimeError("Wippy test dependency is missing; run make setup first")
    for package in packages:
        shutil.copy2(package, vendor)
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=60)
    subprocess.run([str(RUNTIME), "test", "--host", "bee.client:terminal"], cwd=folder, check=True, timeout=60)

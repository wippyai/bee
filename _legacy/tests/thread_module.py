"""Threads module in isolation: definition, linked dependency interface, no desktop closure."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME, stage_values

MODULE = ROOT / "modules/threads"
PERSIST = ROOT / "modules/persist"
HOST = ROOT / "tests/fixtures/modules/threads/src"


def stage(folder, mutate=None):
    shutil.copytree(MODULE, folder / "modules/threads")
    shutil.copytree(PERSIST, folder / "modules/persist")
    shutil.copytree(HOST, folder / "src/host")
    stage_values(folder)
    # Compile the optional adapter against Hive's real public value contract;
    # the isolated owner has no Hive implementation or supervisor dependency.
    protocol = folder / "src/hive"
    protocol.mkdir()
    shutil.copy2(ROOT / "modules/hive/src/types.lua", protocol / "types.lua")
    hive_index = yaml.safe_load((ROOT / "modules/hive/src/_index.yaml").read_text())
    public_types = next(entry for entry in hive_index["entries"] if entry["name"] == "types")
    (protocol / "_index.yaml").write_text(yaml.safe_dump(
        {"version": "1.0", "namespace": "bee.hive", "entries": [public_types]}, sort_keys=False))
    # The staged services attach the production app policies.
    shutil.copytree(ROOT / "src/security/threads", folder / "src/security/threads")
    (folder / "wippy.lock").write_text("""directories:
  modules: .wippy
  src: ./src
modules:
  - name: bee/values
    version: 0.1.0-dev
  - name: bee/persist
    version: 0.1.0-dev
  - name: bee/threads
    version: 0.1.0-dev
""")
    (folder / ".wippy.yaml").write_text("""version: '1.0'
shutdown:
  timeout: 2s
workspace:
  replacements:
    bee/values: ./modules/values
    bee/persist: ./modules/persist
    bee/threads: ./modules/threads
""")
    if mutate:
        mutate(folder)
    return folder


def run(folder, *arguments, ok=True, env=None):
    result = subprocess.run([str(RUNTIME), *arguments], cwd=folder, env={**os.environ, **(env or {})},
                            capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    assert (result.returncode == 0) == ok, output
    return output


def main():
    with tempfile.TemporaryDirectory(prefix="bee-thread-module-") as directory:
        folder = stage(Path(directory))
        staged = sorted(str(p.relative_to(folder)) for p in folder.rglob("_index.yaml"))
        expected = sorted([str(p.relative_to(ROOT)) for module in (MODULE, PERSIST, ROOT / "modules/values") for p in module.rglob('_index.yaml')] + ['src/host/_index.yaml', 'src/hive/_index.yaml', 'src/security/threads/_index.yaml'])
        assert staged == expected, staged
        run(folder, "lint")
        database = folder / "threads.db"
        output = run(folder, "run", "threads-isolation", env={"BEE_THREADS_DB": str(database)})
        assert "threads module: definition, linked target_db, isolated closure, authority and lifecycle contracts" in output, output
        assert database.exists(), "the owner service did not open the linked database"

    def broken_target(folder):
        index = folder / "modules/threads/src/_index.yaml"
        document = yaml.safe_load(index.read_text())
        for entry in document["entries"]:
            if entry["name"] == "target_db":
                entry["targets"] = [{"entry": "bee.threads:missing_ref", "path": ".resource_ref"}]
        index.write_text(yaml.safe_dump(document, sort_keys=False))

    # The runtime linker must reject a dangling database target before any
    # service starts or the thread owner creates its schema.
    with tempfile.TemporaryDirectory(prefix="bee-thread-module-") as directory:
        folder = stage(Path(directory), broken_target)
        run(folder, "lint")
        output = run(folder, "run", "threads-isolation", ok=False, env={"BEE_THREADS_DB": str(folder / "threads.db")})
        assert "unresolved requirements" in output and "bee.threads:missing_ref" in output, output
        assert not (folder / "threads.db").exists(), "rejected dependency created the thread database"

    print("Threads module: standalone host, lint, linked target_db default, isolated closure, authority and lifecycle contracts through bindings, unlinked database reference refused")


if __name__ == "__main__":
    main()

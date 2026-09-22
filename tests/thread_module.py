"""Threads module in isolation: definition, linked dependency interface, no desktop closure."""
from pathlib import Path
import os
import shutil
import sqlite3
import subprocess
import tempfile
import yaml
from workspace import ROOT, RUNTIME

MODULE = ROOT / "modules/threads"
PERSIST = ROOT / "modules/persist"
HOST = ROOT / "tests/fixtures/modules/threads/src"


def stage(folder, mutate=None):
    shutil.copytree(MODULE, folder / "modules/threads")
    shutil.copytree(PERSIST, folder / "modules/persist")
    shutil.copytree(HOST, folder / "src/host")
    (folder / "wippy.lock").write_text("""directories:
  modules: .wippy
  src: ./src
modules:
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
        assert staged == ["modules/persist/src/_index.yaml", "modules/threads/src/_index.yaml", "modules/threads/src/approvals/_index.yaml", "modules/threads/src/carrier/_index.yaml", "modules/threads/src/delivery/_index.yaml", "modules/threads/src/persist/_index.yaml", "modules/threads/src/projection/_index.yaml", "modules/threads/src/records/_index.yaml", "modules/threads/src/service/_index.yaml", "src/host/_index.yaml"], staged
        run(folder, "lint")
        database = folder / "threads.db"
        output = run(folder, "run", "threads-isolation", env={"BEE_THREADS_DB": str(database)})
        assert "threads module: definition, linked target_db, isolated closure, journal contract, authority and lifecycle contracts" in output, output
        assert database.exists(), "journal did not open the linked database"

    def broken_target(folder):
        index = folder / "modules/threads/src/_index.yaml"
        document = yaml.safe_load(index.read_text())
        for entry in document["entries"]:
            if entry["name"] == "target_db":
                entry["targets"] = [{"entry": "bee.threads:missing_ref", "path": ".resource_ref"}]
        index.write_text(yaml.safe_dump(document, sort_keys=False))

    # The runtime linker leaves a dangling target unfilled without an error, so
    # the module itself refuses to run with an unlinked database reference.
    with tempfile.TemporaryDirectory(prefix="bee-thread-module-") as directory:
        folder = stage(Path(directory), broken_target)
        run(folder, "lint")
        output = run(folder, "run", "threads-isolation", ok=False, env={"BEE_THREADS_DB": str(folder / "threads.db")})
        assert "not linked" in output, output
        # The SQLite resource auto-starts, so the file exists; the journal schema must not.
        with sqlite3.connect(folder / "threads.db") as db:
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert "bee_threads" not in tables and "bee_thread_schema_migrations" not in tables, tables

    print("Threads module: standalone host, lint, linked target_db default, isolated closure, journal through contract, unlinked database reference refused")


if __name__ == "__main__":
    main()

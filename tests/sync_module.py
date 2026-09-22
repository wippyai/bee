"""Headless node metadata + ledger acceptance on one retained SQLite database."""
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from workspace import ROOT, RUNTIME, database_environment


def main():
    with tempfile.TemporaryDirectory(prefix="bee-sync-module-") as directory:
        folder = Path(directory)
        for module in ("application", "node", "persist", "sync", "threads"):
            shutil.copytree(ROOT / "modules" / module, folder / "modules" / module)
        shutil.copytree(ROOT / "tests/fixtures/sync_module", folder / "src/probe")
        (folder / "src" / "_index.yaml").write_text("""version: '1.0'
namespace: bee
entries:
- name: dependency_persist
  kind: ns.dependency
  component: bee/persist
  version: 0.1.0-dev
- name: dependency_sync
  kind: ns.dependency
  component: bee/sync
  version: 0.1.0-dev
  parameters:
  - name: target_sender
    value: bee.sync_probe:sender
  - name: target_exports
    value: bee:sync_exports
- name: dependency_node
  kind: ns.dependency
  component: bee/node
  version: 0.1.0-dev
  parameters:
  - name: target_db
    value: bee.sync_probe:node_db
- name: sync_exports
  kind: registry.entry
  data: {exports: []}
- name: workers
  kind: process.host
  host: {workers: 2, max_processes: 8}
  lifecycle: {auto_start: true}
""")
        probe_index = folder / "src" / "probe" / "_index.yaml"
        (folder / "src" / "probe" / "sender.lua").write_text("""local transaction = require(\"transaction\")
local version = require(\"version\")
return {send = function(_: string, _: version.Descriptor, _: string, _: {timeout: string?, source_cursor: integer}): transaction.Result return transaction.failure(\"UNAVAILABLE\", \"probe sender is not used\") end}
""")
        probe_index.write_text(probe_index.read_text() + """\n- name: sender
  kind: library.lua
  source: file://sender.lua
  imports: {transaction: bee.persist:transaction, version: bee.sync:version}
""")
        (folder / "wippy.lock").write_text("""directories:
  modules: .wippy
  src: ./src
modules:
  - name: bee/persist
    version: 0.1.0-dev
  - name: bee/application
    version: 0.1.0-dev
  - name: bee/node
    version: 0.1.0-dev
  - name: bee/sync
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
    bee/application: ./modules/application
    bee/node: ./modules/node
    bee/sync: ./modules/sync
    bee/threads: ./modules/threads
""")
        environment = database_environment(folder)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=folder, check=True, timeout=60, env=environment)
        for phase in ("FIRST", "SECOND"):
            result = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee.sync_probe:workers", "--", "sync-probe"],
                cwd=folder, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=40)
            marker = "NODE_SYNC_" + phase + "_BOOT_PASS"
            if result.returncode or marker not in result.stdout or "service failed" in result.stdout:
                print(result.stdout)
                raise SystemExit("Node sync acceptance failed in " + phase)
            print(marker)
        selected = folder / ".wippy" / "selected-node.db"
        with sqlite3.connect(selected) as connection:
            names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert "bee_sync_projections" in names, "Node owner did not use its injected database resource"
        print("Node sync: public dispatch, permissions, CAS, replay, ledger catch-up and same-database restart passed")


if __name__ == "__main__":
    main()

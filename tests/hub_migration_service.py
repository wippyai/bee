"""Real Hub facade/publication/migration acceptance against disposable artifacts."""
import json
import os
from pathlib import Path
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time

import yaml

from hub_recovery import prepare_fixture

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ["BEE_RUNTIME"]).resolve()


def entry(namespace, name, kind, data=None, meta=None):
    return {"ID": {"ns": namespace, "name": name}, "Kind": kind, "Data": data or {}, "Meta": meta or {}}


def main():
    folder = Path(tempfile.mkdtemp(prefix="bee-hub-migration-service-"))
    server = None
    server_log = None
    try:
        binary = folder / "hub-fixture"
        subprocess.run(["go", "-C", str(ROOT / "native"), "build", "-mod=readonly", "-o", str(binary),
                        "../tests/hub_migration_fixture.go"], check=True)
        source = (ROOT / "tests/fixtures/hub_migration_service/migration.lua").read_text()
        packages = {
            "acme/app@1.0.0": [entry("acme.app", "definition", "ns.definition"),
                               entry("acme.app", "storage", "ns.dependency", {"component": "acme/storage", "version": "1.0.0"})],
            "acme/storage@1.0.0": [entry("acme.storage", "definition", "ns.definition"),
                                   entry("acme.storage", "first", "function.lua",
                                         {"source": source, "method": "run", "modules": ["sql"]},
                                         {"type": "migration", "target_db": "probe:db", "timestamp": "2026-09-12T12:00:00Z"})],
        }
        second_source = source.replace("fixture_payload", "fixture_second").replace(
            "    local tx = assert(db:begin())",
            '    local gate, problem = db:query("SELECT ready FROM fixture_gate")\n'
            '    if not gate then db:release(); error(tostring(problem)) end\n'
            '    local tx = assert(db:begin())')
        packages["acme/app@1.1.0"] = [entry("acme.app", "definition", "ns.definition"),
                                       entry("acme.app", "storage", "ns.dependency", {"component": "acme/storage", "version": "1.1.0"})]
        packages["acme/storage@1.1.0"] = packages["acme/storage@1.0.0"] + [
            entry("acme.storage", "second", "function.lua", {"source": second_source, "method": "run", "modules": ["sql"]},
                  {"type": "migration", "target_db": "probe:db", "timestamp": "2026-09-12T13:00:00Z"})]
        packages["acme/app@1.2.0"] = [entry("acme.app", "definition", "ns.definition"),
                                       entry("acme.app", "storage", "ns.dependency", {"component": "acme/storage", "version": "1.2.0"})]
        packages["acme/storage@1.2.0"] = [entry("acme.storage", "definition", "ns.definition"),
            entry("acme.storage", "target_db", "ns.requirement", {"default": "raw:default",
                  "targets": [{"entry": "acme.storage:first", "path": ".meta.target_db"}]}),
            entry("acme.storage", "first", "function.lua", {"source": source, "method": "run", "modules": ["sql"]},
                  {"type": "migration", "target_db": "raw:database", "timestamp": "2026-09-12T12:00:00Z"})]
        descriptions = folder / "packages.json"
        descriptions.write_text(json.dumps(packages))
        server_log = (folder / "server.log").open("w")
        server = subprocess.Popen([str(binary), str(descriptions)], stdout=subprocess.PIPE, stderr=server_log, text=True)
        with selectors.DefaultSelector() as ready:
            ready.register(server.stdout, selectors.EVENT_READ)
            assert ready.select(15), "fixture Hub did not announce its listener"
            url = server.stdout.readline().strip()
        assert url.startswith("http://127.0.0.1:"), url
        for mode in ("absent", "applied", "denied", "crash", "partial", "tamper", "linked"):
            workspace = folder / mode
            workspace.mkdir()
            prepare_fixture(workspace)
            (workspace / ".wippy").mkdir()
            probe = workspace / "src/migration_probe"
            probe.mkdir()
            shutil.copy2(ROOT / "tests/fixtures/hub_migration_service/probe.lua", probe / "probe.lua")
            entries = [
                {"name": "db", "kind": "db.sql.sqlite", "file": ".wippy/migration.db"},
                {"name": "caller", "kind": "security.policy", "policy": {"actions": ["funcs.call"], "resources": ["bee.hub:call"], "effect": "allow"}},
                {"name": "manage", "kind": "security.policy", "policy": {"actions": ["bee.hub.manage"], "resources": ["acme/app"], "effect": "allow"}},
                {"name": "read", "kind": "security.policy", "policy": {"actions": ["registry.get", "bee.hub.read"], "resources": "*", "effect": "allow"}},
                {"name": "migration_function", "kind": "security.policy", "groups": ["bee.hub:execution_scope"], "policy": {"actions": ["funcs.call"], "resources": ["acme.storage:first", "acme.storage:second"], "effect": "allow"}},
                {"name": "run", "kind": "process.lua", "source": "file://probe.lua", "method": "crash" if mode == "tamper" else mode, "modules": ["funcs", "registry", "logger", "sql"],
                 "security": {"policies": ["probe:caller", "probe:manage", "probe:read"]},
                 "meta": {"command": {"name": "migration-service-probe", "security": {"actor": {"id": "probe.migration_service"}}}}},
            ]
            if mode == "tamper":
                entries.append({"name": "fixture_operator", "kind": "security.policy",
                                "policy": {"actions": ["registry.apply", "registry.update.function.lua"],
                                           "resources": "*", "effect": "allow"}})
                entries[-2]["security"]["policies"].append("probe:fixture_operator")
            if mode == "partial":
                entries.append({"name": "fixture_prerequisite", "kind": "security.policy",
                                "policy": {"actions": ["db.get"], "resources": ["probe:db"], "effect": "allow"}})
                entries[-2]["security"]["policies"].append("probe:fixture_prerequisite")
            if mode != "denied":
                entries.append({"name": "migration_database", "kind": "security.policy", "groups": ["bee.hub:execution_scope"],
                                "policy": {"actions": ["db.get"], "resources": ["probe:db"], "effect": "allow"}})
            (probe / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "probe", "entries": entries}, sort_keys=False))
            command = [str(RUNTIME), "run", "--verbose", "--host", "bee:workers", "--", "migration-service-probe"]
            environment = {"HOME": os.environ["HOME"], "PATH": os.environ["PATH"],
                           "WIPPY_REGISTRY": url, "XDG_CONFIG_HOME": str(workspace / "config")}
            if mode in ("crash", "tamper"):
                service = workspace / "src/hub/service.lua"
                original = service.read_text()
                anchor = "    if result then work.rows = result.rows end\n"
                assert original.count(anchor) == 1
                service.write_text(original.replace(anchor, anchor + '    print("HUB_MIGRATION_SCHEMA_COMMITTED")\n    while true do end\n'))
                log = workspace / "crash-runtime.log"
                with log.open("w") as output_file:
                    runtime = subprocess.Popen(command, cwd=workspace, env=environment, stdout=output_file,
                                               stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        deadline = time.monotonic() + 45
                        while time.monotonic() < deadline and runtime.poll() is None:
                            if "HUB_MIGRATION_SCHEMA_COMMITTED" in log.read_text():
                                break
                            time.sleep(0.05)
                        assert "HUB_MIGRATION_SCHEMA_COMMITTED" in log.read_text(), log.read_text()
                    finally:
                        if runtime.poll() is None:
                            os.killpg(runtime.pid, 9)
                        runtime.wait(timeout=10)
                assert runtime.returncode == -9, "fixture did not SIGKILL the runtime"
                service.write_text(original)
                entries = yaml.safe_load((probe / "_index.yaml").read_text())
                for item in entries["entries"]:
                    if item["name"] == "run":
                        item["method"] = "tamper" if mode == "tamper" else "recover"
                (probe / "_index.yaml").write_text(yaml.safe_dump(entries, sort_keys=False))
            result = subprocess.run(command, cwd=workspace, env=environment,
                                    capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            (workspace / "runtime.log").write_text(output)
            assert result.returncode == 0 and f"HUB_MIGRATION_SERVICE_PASS {mode}" in output, output
            database = workspace / ".wippy/migration.db"
            assert database.is_file(), "missing target database"
            with sqlite3.connect(database) as connection:
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if mode in ("applied", "crash", "tamper", "linked"):
                    assert tables == {"_migrations", "fixture_payload"}, tables
                    assert connection.execute("SELECT id FROM _migrations").fetchall() == [("acme.storage:first",)]
                    assert connection.execute("SELECT value FROM fixture_payload").fetchall() == [("committed",)]
                elif mode == "partial":
                    assert tables == {"_migrations", "fixture_payload", "fixture_second", "fixture_gate"}, tables
                    assert connection.execute("SELECT id FROM _migrations ORDER BY id").fetchall() == [("acme.storage:first",), ("acme.storage:second",)]
                    assert connection.execute("SELECT value FROM fixture_payload").fetchall() == [("committed",)]
                    assert connection.execute("SELECT value FROM fixture_second").fetchall() == [("committed",)]
                else:
                    assert tables == set(), tables
    except BaseException:
        print(f"Hub migration service fixture preserved: {folder}")
        raise
    finally:
        if server is not None:
            server.terminate()
            server.wait(timeout=10)
        if server_log is not None:
            server_log.close()
    shutil.rmtree(folder)
    print("Hub migration service: real up/replay, committed-schema SIGKILL/restart, partial failure/retry, changed-definition refusal, requirement-linked target, orphan removal block, absent ledger and denied database grant pass")


if __name__ == "__main__":
    main()

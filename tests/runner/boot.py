"""Boot the application with strict security and fresh node state.

The ordinary suite composition disables owner scheduling. This workspace
loads only the boot/residency tests, so real backlog probes run without those
seams or the suite's synthetic contract owners.
"""
from pathlib import Path
import json
import sqlite3
import shutil
import subprocess
import sys
import uuid

import yaml

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "tests/.wippy/boot" / uuid.uuid4().hex


def check_restarted_attachment(toolchain, root, workspace, application, environment):
    with sqlite3.connect(root / "bee.db") as database:
        assert database.execute("SELECT 1 FROM _migrations WHERE id = 'bee.persist:state_writer'").fetchone()
        assert database.execute("SELECT 1 FROM bee_node_desktops").fetchone()
    owner = application / "src/node/service/owner.lua"
    baseline = owner.read_text()
    barrier = '''        local controller = process.registry.lookup("bee.test.display.snapshot", process.registry.LOCAL)
        if controller then
            local release = assert(process.listen("bee.test.display.release", {message = true}))
            assert(process.send(tostring(controller), "bee.test.display.snapshot", {}))
            assert((release:receive()))
            process.unlisten(release)
        end
'''
    owner.write_text(baseline.replace('        value.desktop = chosen\n', '        value.desktop = chosen\n' + barrier).replace(
        '    logger:info("Node ready",', '''    local observer = process.registry.lookup("bee.test.node.ready", process.registry.LOCAL)
    if observer then assert(process.send(tostring(observer), "bee.test.node.ready", {})) end
    logger:info("Node ready",'''))
    policy = application / "src/node/security/_index.yaml"
    original_policy = policy.read_text()
    document = yaml.safe_load(original_policy)
    names = next(entry for entry in document["entries"] if entry["name"] == "owner_names")
    names["policy"]["resources"].extend(["bee.test.display.snapshot", "bee.test.node.ready"])
    policy.write_text(yaml.safe_dump(document, sort_keys=False))
    try:
        result = subprocess.run([str(toolchain), "-c", "test", "--host", "bee:terminal",
                                 "--set", "security.strict_mode=true",
                                 "-o", "bee:terminal:hide_logs=false",
                                 "-o", "bee:gateway_listener:addr=127.0.0.1:0",
                                 "test", "bee.tests.node:attach_restart_test"],
                                cwd=workspace, env=environment, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        (root / "attach-restart.log").write_text(output)
        assert result.returncode == 0, output
        print("PASS: display attaches after its first watched owner exits on a restarted node")
    finally:
        owner.write_text(baseline)
        policy.write_text(original_policy)


def check_app_namespaces(toolchain, root, workspace, application, environment):
    apps = ("help", "library", "processes", "settings", "terminal")
    with sqlite3.connect(root / "bee.db") as connection:
        desktop, workspace_id = connection.execute(
            "SELECT id, workspace_id FROM bee_node_desktops ORDER BY id LIMIT 1").fetchone()
        assert not connection.execute(
            "SELECT 1 FROM _migrations WHERE id = 'bee.node.migrations:app_namespaces'").fetchone()
        for name in apps:
            connection.execute(
                "INSERT INTO bee_node_instances(id, desktop_id, app, args, created_at, workspace_id) VALUES (?, ?, ?, ?, ?, ?)",
                ("namespace-" + name, desktop, "bee.apps." + name + ":app",
                 json.dumps({"retained": name}), "2026-10-01T00:00:00Z", workspace_id))
        writer = json.loads(connection.execute(
            "SELECT description FROM _migrations WHERE id = 'bee.persist:state_writer'").fetchone()[0])
        writer["version"] = "0.2.0-dev"
        connection.execute("UPDATE _migrations SET description = ? WHERE id = 'bee.persist:state_writer'",
                           (json.dumps(writer),))
    identity = application / "src/env/identity/_index.yaml"
    document = json.loads(identity.read_text())
    for entry in document["entries"]:
        if entry["name"] == "state_writer_version":
            entry["source"] = 'return {version = "0.2.0-alpha.5", build = "fixture", format_revision = 1}'
    identity.write_text(json.dumps(document))
    shutil.copy2(REPO / "src/node/migrations/_index.yaml", application / "src/node/migrations/_index.yaml")
    result = subprocess.run([str(toolchain), "-c", "test", "--host", "bee:terminal",
                             "--set", "security.strict_mode=true",
                             "-o", "bee:gateway_listener:addr=127.0.0.1:0",
                             "test", "bee.tests.node:app_namespace_restart_test"],
                            cwd=workspace, env=environment, capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    (root / "app-namespace-restart.log").write_text(output)
    assert result.returncode == 0, output
    with sqlite3.connect(root / "bee.db") as connection:
        for name in apps:
            row = connection.execute(
                "SELECT app, args, desktop_id, workspace_id, created_at FROM bee_node_instances WHERE id = ?",
                ("namespace-" + name,)).fetchone()
            assert row is not None, (name, output)
            assert row[0] == "bee.apps." + name + ".app:app", row
            assert json.loads(row[1]) == {"retained": name}, row
            assert row[2:] == (desktop, workspace_id, "2026-10-01T00:00:00Z"), row
    print("PASS: dev-labelled older state opens on alpha.5; five saved app definitions migrate and reopen")


def check_future_writer(toolchain, root, workspace, application, environment):
    database = root / "bee.db"
    with sqlite3.connect(database) as connection:
        writer = json.loads(connection.execute(
            "SELECT description FROM _migrations WHERE id = 'bee.persist:state_writer'").fetchone()[0])
        writer["version"] = "0.2.0-dev"
        connection.execute("UPDATE _migrations SET description = ? WHERE id = 'bee.persist:state_writer'",
                           (json.dumps(writer),))
        connection.execute("INSERT INTO _migrations(id, description) VALUES (?, ?)",
                           ("future.schema:unknown", "future state schema"))
    index_path = application / "src/persist/_index.yaml"
    index = yaml.safe_load(index_path.read_text())
    reporter = next(entry for entry in index["entries"] if entry["name"] == "state_refusal")
    reporter["modules"].append("time")
    index_path.write_text(yaml.safe_dump(index, sort_keys=False))
    script = application / "src/persist/state_refusal.lua"
    script.write_text('local time = require("time")\n' + script.read_text().replace(
        '    assert(io.eprint(message))', '    time.sleep("50ms")\n    assert(io.eprint(message))'))
    command = [str(toolchain), "run", "--silent", "-x", "bee.node:headless", "--host", "bee:terminal",
               "--set", "security.strict_mode=true", "-o", "bee:gateway_listener:addr=127.0.0.1:0"]
    try:
        result = subprocess.run(command, cwd=workspace, env=environment,
                                capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        (root / "future-refusal.log").write_bytes((error.stdout or b"") + (error.stderr or b""))
        raise AssertionError("future-writer refusal must finish cleanup and exit within 10 seconds") from error
    output = result.stdout + result.stderr
    (root / "future-refusal.log").write_text(output)
    assert result.returncode == 1, f"future-writer refusal exit={result.returncode}: {output}"
    assert "Bee refuses to start:" in output, output
    assert str(database.parent) in output, output
    assert "was written by Bee 0.2.0-dev" in output, output
    assert "Install Bee containing schema future.schema:unknown or newer" in output, output
    assert "is running" not in output and "no such table" not in output, output
    print("PASS: future writer prints its refusal before clean non-zero shutdown")



def run(toolchain, fault):
    root = ROOT / ("failing-probe" if fault else "healthy")
    shutil.rmtree(root, ignore_errors=True)
    application = root / "application"
    shutil.copytree(REPO / "src", application / "src")
    shutil.copy2(REPO / "wippy.yaml", application / "wippy.yaml")
    if not fault:
        migration_path = application / "src/node/migrations/_index.yaml"
        migrations = yaml.safe_load(migration_path.read_text())
        migrations["entries"] = [entry for entry in migrations["entries"] if entry["name"] != "app_namespaces"]
        migration_path.write_text(yaml.safe_dump(migrations, sort_keys=False))
    if fault:
        gateway_index = application / "src/gateway/service/_index.yaml"
        document = yaml.safe_load(gateway_index.read_text())
        backlog = next(entry for entry in document["entries"] if entry["name"] == "backlog")
        backlog["source"] = "file://boot_backlog_probe.lua"
        backlog["modules"].append("sql")
        shutil.copy2(REPO / "tests/lua/node/boot_backlog_probe.lua", gateway_index.parent)
        gateway_index.write_text(yaml.safe_dump(document, sort_keys=False))
    workspace = root / "workspace"
    source = workspace / "lua"
    source.mkdir(parents=True)
    index = yaml.safe_load((REPO / "tests/lua/node/_index.yaml").read_text())
    entries = [entry for entry in index["entries"] if entry["name"] in
               ("boot_residency_test", "idle_services_test", "app_namespace_restart_test", "attach_restart_test")]
    assert len(entries) == 4
    for entry in entries:
        shutil.copy2(REPO / "tests/lua/node" / entry["source"].removeprefix("file://"), source)
        # The display boot case runs only in this fresh runtime; it must not
        # claim a desktop in the shared application suites' node.
        entry["meta"]["type"] = "test"
        if fault and entry["name"] == "boot_residency_test":
            entry["method"] = "run_fault"
    entries.append({"name": "dependency", "kind": "ns.dependency", "component": "bee/bee", "version": "*"})
    (source / "_index.yaml").write_text(yaml.safe_dump(
        {"version": "1.0", "namespace": "bee.tests.node", "entries": entries}, sort_keys=False))
    gateway = yaml.safe_load((REPO / "tests/lua/gateway/_index.yaml").read_text())
    gateway["entries"] = [entry for entry in gateway["entries"] if entry["name"] in
                          ("effects_scope_probe", "effects_scope_test")]
    assert len(gateway["entries"]) == 2
    gateway_source = source / "gateway"
    gateway_source.mkdir()
    for entry in gateway["entries"]:
        shutil.copy2(REPO / "tests/lua/gateway" / entry["source"].removeprefix("file://"), gateway_source)
        if entry["meta"]["type"] == "boot_test":
            entry["meta"]["type"] = "test"
    (gateway_source / "_index.yaml").write_text(yaml.safe_dump(gateway, sort_keys=False))
    shutil.copy2(REPO / "tests/wippy.lock", workspace / "wippy.lock")
    (workspace / ".wippy.yaml").write_text(yaml.safe_dump(
        {"version": "1.0", "workspace": {"replacements": {"bee/bee": str(application)}},
         "cluster": {"name": "bee-boot-" + root.parent.name + "-" + root.name},
         "lua": {"cache": {"dir": str(Path(sys.argv[2]).resolve()),
                           "mode": sys.argv[3] if len(sys.argv) > 3 else 'readwrite'}} if len(sys.argv) > 2 else {}}, sort_keys=False))
    (workspace / ".wippy").mkdir()
    (workspace / ".wippy/vendor").symlink_to(REPO / "tests/.wippy/vendor", target_is_directory=True)
    home = root / "home"
    temporary = root / "tmp"
    home.mkdir()
    temporary.mkdir()
    if fault:
        with sqlite3.connect(root / "bee.db") as fixture:
            fixture.execute("CREATE TABLE bee_test_boot_probe (attempt INTEGER NOT NULL)")
    environment = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
                   "XDG_DATA_HOME": str(home / ".local/share"), "XDG_CACHE_HOME": str(home / ".cache"),
                   "TMPDIR": str(temporary), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
                   "BEE_DB": str(root / "bee.db"), "BEE_ENV": str(root / "bee.env"),
                   "WIPPY_CACHE_DIR": str(REPO / ".wippy/cache/boot"), "GOMAXPROCS": "2", "GOMEMLIMIT": "1GiB"}
    result = subprocess.run([str(toolchain), "-c", "test", "--host", "bee:terminal",
                             "--set", "security.strict_mode=true",
                             "-o", "bee:terminal:hide_logs=false",
                             "-o", "bee:gateway_listener:addr=127.0.0.1:0",
                             "test", "bee.tests.node:boot_residency_test", "bee.tests.node:idle_services_test",
                             "bee.tests.gateway:effects_scope_test"],
                            cwd=workspace, env=environment, capture_output=True, text=True, timeout=60)
    log = result.stdout + result.stderr
    (root / "output.log").write_text(log)
    if fault and not result.returncode:
        assert log.count("Demand backlog probe failed") >= 2, "probe failures were not reported"
        assert "bee.gateway.service:external_service" in log and "injected Gateway boot backlog failure" in log
    if result.returncode:
        print(result.stdout + result.stderr)
    else:
        print("PASS: " + ("failing probe retries without restarting Hive or losing its display" if fault else "fresh strict boot retains resident names, serves a display desktop and dispatches Gateway effects"))
        if not fault:
            check_restarted_attachment(toolchain, root, workspace, application, environment)
            check_app_namespaces(toolchain, root, workspace, application, environment)
            check_future_writer(toolchain, root, workspace, application, environment)
    return result.returncode


def main():
    toolchain = Path(sys.argv[1]).resolve()
    return max(run(toolchain, False), run(toolchain, True))


if __name__ == "__main__":
    sys.exit(main())

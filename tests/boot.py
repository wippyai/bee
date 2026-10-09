"""Boot the application with strict security and fresh node state.

The ordinary suite composition disables owner scheduling. This workspace
loads only the boot/residency tests, so real backlog probes run without those
seams or the suite's synthetic contract owners.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

import yaml

REPO = Path(__file__).resolve().parents[1]
ROOT = REPO / "tests/.wippy/boot"


def run(toolchain, fault):
    root = ROOT / ("failing-probe" if fault else "healthy")
    shutil.rmtree(root, ignore_errors=True)
    application = root / "application"
    shutil.copytree(REPO / "src", application / "src")
    shutil.copy2(REPO / "wippy.yaml", application / "wippy.yaml")
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
               ("boot_residency_test", "idle_services_test")]
    assert len(entries) == 2
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
        {"version": "1.0", "workspace": {"replacements": {"bee/bee": str(application)}}}, sort_keys=False))
    shutil.copytree(REPO / "tests/.wippy/vendor", workspace / ".wippy/vendor")
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
                   "WIPPY_CACHE_DIR": str(root / "cache")}
    result = subprocess.run([str(toolchain), "-c", "test", "--host", "bee:terminal",
                             "--set", "security.strict_mode=true",
                             "-o", "bee:terminal:hide_logs=false",
                             "-o", "bee.gateway.api:gateway_listener:addr=127.0.0.1:0",
                             "test", "bee.tests.node:boot_residency_test", "bee.tests.node:idle_services_test",
                             "bee.gateway:effects_scope_test"],
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
    return result.returncode


def main():
    toolchain = Path(sys.argv[1]).resolve()
    return max(run(toolchain, False), run(toolchain, True))


if __name__ == "__main__":
    sys.exit(main())

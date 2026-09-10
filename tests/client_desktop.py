"""Actual independent desktop owners over native viewport grants."""
from workspace import database_environment
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()


def run(workspace_appearance=False, command="desktop-client-probe", shared_store=False, storage_delay=False):
    with tempfile.TemporaryDirectory(prefix="bee-client-desktop-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/desktop_client", project / "src/client_probe")
        if shared_store:
            fixture_manifest = project / "src/client_probe/_index.yaml"
            data = yaml.safe_load(fixture_manifest.read_text())
            next(entry for entry in data["entries"] if entry["name"] == "right_policy")["policy"]["resources"] = ["bee.client.db:left"]
            fixture_manifest.write_text(yaml.safe_dump(data, sort_keys=False))
        if workspace_appearance:
            fixture = project / "src/client_probe/main.lua"
            code = fixture.read_text()
            permission = 'appearance = label == "left"'
            assertion = '    if not themed then error("Missing themed client state") end\n'
            assert code.count(permission) == code.count(assertion) == 1
            code = code.replace(permission, permission + ', workspace_appearance = label == "left"')
            code = code.replace(assertion, assertion + '    wait_text(right_screen, "48;2;12;12;12")\n')
            fixture.write_text(code)
        shutil.copytree(ROOT / "tests/fixtures/client_storage/client_database", project / "src/client_databases")
        databases = project / "src/client_databases/_index.yaml"
        database_entries = yaml.safe_load(databases.read_text())
        database_entries["entries"].append({"name": "observer", "kind": "db.sql.sqlite", "file": "${env:bee:client_db_path}.observer"})
        database_entries["entries"].append({"name": "status", "kind": "db.sql.sqlite", "file": "${env:bee:client_db_path}.status"})
        databases.write_text(yaml.safe_dump(database_entries, sort_keys=False))
        config = project / "src/_index.yaml"
        value = yaml.safe_load(config.read_text())
        value["entries"].append({"name": "client_db_path", "kind": "env.variable", "storage": "bee:workspace_environment",
                                 "variable": "BEE_CLIENT_DB", "default": str(root / "build-client.db"), "readonly": True})
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        if command in ("thread-status-probe", "retained-supervisor-probe"):
            # The disposable presenter copy stamps each frame with its PID.
            # This lets the fixture distinguish an F12 replacement from the
            # retained output of the viewport it replaced.
            presenter = project / "src/core/terminal/main.lua"
            source = presenter.read_text()
            label = '"Workspace " .. workspace_id:sub(1, 8)'
            assert source.count(label) == 1, "unexpected terminal presenter label anchor"
            presenter.write_text(source.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)', 1))
        if storage_delay:
            operations = project / "src/core/client/desktop_storage.lua"
            code = operations.read_text().replace('local security = require("security")', 'local security = require("security")\nlocal time = require("time")')
            code = code.replace('function M.allocate(value: unknown): Reply', 'function M.allocate(value: unknown): Reply\n    if type(value) == "table" and value.desktop_id == string.rep("c", 32) then time.sleep("6s") end')
            operations.write_text(code)
            manifest = project / "src/core/client/_index.yaml"
            values = yaml.safe_load(manifest.read_text())
            for entry in values["entries"]:
                if entry.get("source") == "file://desktop_storage.lua": entry["modules"].append("time")
            manifest.write_text(yaml.safe_dump(values, sort_keys=False))
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text()
            code = code.replace('    local first, first_screen = attach()', '''    assert(process.send(supervisor, "bee.retained.desktops", {version = 1, workspace_id = workspace_id,
        request_id = "slow-allocation", op = "allocate", desktop_id = string.rep("c", 32)}))
    storage("list", nil, "BUSY", 0)
    local first, first_screen = attach()''', 1)
            code = code.replace('    wait_text(first_screen, "OWNER_alive_OK")', '''    wait_text(first_screen, "OWNER_alive_OK")
    local slow = channel.select({catalogs:case_receive(), time.after("6s"):case_receive()})
    assert(slow.ok and slow.channel == catalogs, "Storage timeout did not reply")
    local slow_message = slow.value
    assert(tostring(slow_message:from()) == supervisor)
    local slow_data: unknown = slow_message:payload():data()
    assert(type(slow_data) == "table" and slow_data.request_id == "slow-allocation"
        and slow_data.code == "UNAVAILABLE" and slow_data.desktop_id == string.rep("c", 32))
    time.sleep("1500ms")
    storage("allocate", string.rep("a", 32), "OK", 0)''', 1)
            fixture.write_text(code)
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        lint = subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, capture_output=True, text=True)
        assert lint.returncode == 0, lint.stdout + lint.stderr
        pack = root / "client-desktop.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("pack" if packed else "source")
            folder.mkdir()
            # Optional subsystem stores use .wippy defaults inside this disposable host.
            ((folder if packed else project) / ".wippy").mkdir(exist_ok=True)
            args = [str(RUNTIME), "--console", "run"] + ([str(pack)] if packed else [])
            args += [command] + (["shared-store"] if shared_store else []) + [ "--host", "bee:workers", "--set", f"registry.history_path={folder / 'registry.db'}"]
            try:
                result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=40,
                                        env=database_environment(folder, BEE_CLIENT_DB=str(folder / "client.db")))
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b""
                errors = error.stderr or b""
                raise AssertionError(f"Desktop fixture timed out; stdout={output!r}; stderr={errors!r}") from error
            logs = result.stdout + result.stderr
            assert result.returncode == 0, logs
            marker = {
                "desktop-client-probe": "DESKTOP_CLIENT_PROBE_COMPLETE",
                "retained-supervisor-probe": "RETAINED_SUPERVISOR_PROBE_COMPLETE",
                "thread-status-probe": "THREAD_STATUS_PROBE_COMPLETE",
            }[command]
            assert marker in logs, logs
            if command == "retained-supervisor-probe":
                assert "shutdown error" not in logs and "is failed" not in logs, logs
    if command == "retained-supervisor-probe":
        print(f"Retained supervisor source/pack (slow storage={storage_delay}): authorized catalog/allocation and retry, additional activation/replay, independent Terminals, additional F12/save/reactivation with live shell, startup/admission, forged sender denial, controller exclusion, observer/retired launch denial, literal command launch and broker identity, display EXIT revocation, explicit detach/rejoin, same shell, negotiated shutdown")
        return
    if command == "thread-status-probe":
        print("Bound thread status source/pack: host-authorized association, visible owner-derived badge, F12 and fresh-client retention")
        return
    print(f"Desktop clients source/pack ({'shared store' if shared_store else 'workspace appearance' if workspace_appearance else 'independent appearance'}): separate displays, qualified tabs, PTY isolation, F12 dialogs, import retry, retained-terminal restart, isolated Settings and negotiated host shutdown")


if __name__ == "__main__":
    run()
    run(True)
    run(shared_store=True)
    run(command="retained-supervisor-probe")
    run(command="retained-supervisor-probe", storage_delay=True)
    run(command="thread-status-probe")

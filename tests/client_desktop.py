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


def run(workspace_appearance=False, command="desktop-client-probe"):
    with tempfile.TemporaryDirectory(prefix="bee-client-desktop-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/desktop_client", project / "src/client_probe")
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
        if command == "thread-status-probe":
            # The disposable presenter copy stamps each frame with its PID.
            # This lets the fixture distinguish an F12 replacement from the
            # retained output of the viewport it replaced.
            presenter = project / "src/core/terminal/main.lua"
            source = presenter.read_text()
            label = '"Workspace " .. workspace_id:sub(1, 8)'
            assert source.count(label) == 1, "unexpected terminal presenter label anchor"
            presenter.write_text(source.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)', 1))
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
            args += [command, "--host", "bee:workers", "--set", f"registry.history_path={folder / 'registry.db'}"]
            result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=40,
                                    env=database_environment(folder, BEE_CLIENT_DB=str(folder / "client.db")))
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
        print("Retained supervisor source/pack: startup/admission, forged sender denial, controller exclusion, display EXIT revocation, explicit detach/rejoin, same shell, negotiated shutdown")
        return
    if command == "thread-status-probe":
        print("Bound thread status source/pack: host-authorized association, visible owner-derived badge, F12 and fresh-client retention")
        return
    print(f"Desktop clients source/pack ({'workspace appearance' if workspace_appearance else 'independent appearance'}): separate displays, qualified tabs, PTY isolation, F12 dialogs, import retry, retained-terminal restart, isolated Settings and negotiated host shutdown")


if __name__ == "__main__":
    run()
    run(True)
    run(command="retained-supervisor-probe")
    run(command="thread-status-probe")

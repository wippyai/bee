"""Actual independent desktop owners over native viewport grants."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()


def run(workspace_appearance=False):
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
        config = project / "src/_index.yaml"
        value = yaml.safe_load(config.read_text())
        value["entries"].append({"name": "client_db_path", "kind": "env.variable", "storage": "bee:workspace_environment",
                                 "variable": "BEE_CLIENT_DB", "default": str(root / "build-client.db"), "readonly": True})
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, check=True)
        pack = root / "client-desktop.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("pack" if packed else "source")
            folder.mkdir()
            args = [str(RUNTIME), "--console", "run"] + ([str(pack)] if packed else [])
            args += ["desktop-client-probe", "--set", f"registry.history_path={folder / 'registry.db'}"]
            result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=40,
                                    env={**os.environ, "BEE_CLIENT_DB": str(folder / "client.db"),
                                         "BEE_WORKSPACE_DB": str(folder / "workspace.db"), "BEE_THREADS_DB": str(folder / "threads.db")})
            assert result.returncode == 0, result.stdout + result.stderr
    print(f"Desktop clients source/pack ({'workspace appearance' if workspace_appearance else 'independent appearance'}): separate displays, qualified tabs, PTY isolation, F12 dialogs, import retry, retained-terminal restart, isolated Settings and negotiated host shutdown")


if __name__ == "__main__":
    run()
    run(True)

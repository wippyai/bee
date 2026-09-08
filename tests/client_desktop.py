"""Actual independent desktop owners over native viewport grants."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()


def run():
    with tempfile.TemporaryDirectory(prefix="bee-client-desktop-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/desktop_client", project / "src/client_probe")
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
    print("Desktop clients source/pack: separate displays, qualified selected tabs, owned layouts, native PTY isolation, F12, independent exit and retained-terminal client restart")


if __name__ == "__main__":
    run()

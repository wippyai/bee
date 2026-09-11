"""Actual broker-spawn acceptance for the private managed native window app."""
from pathlib import Path
import shutil
import subprocess
import sys
import yaml

sys.path.insert(0, str(Path(__file__).parent))
import workspace

ROOT = Path(__file__).resolve().parents[1]

with workspace.fixture_workspace(unit_tests=False) as folder:
    shutil.copytree(ROOT / "tests/fixtures/managed_window_app", folder / "src/tests/managed_window_app")
    host = folder / "src/_index.yaml"
    document = yaml.safe_load(host.read_text())
    activation = next(entry for entry in document["entries"] if entry["name"] == "harness_activation")
    activation["data"]["bindings"].append("bee.managed_window_fixture:binding")
    host.write_text(yaml.safe_dump(document, sort_keys=False))
    environment = workspace.database_environment(folder)
    subprocess.run([str(workspace.RUNTIME), "lint"], cwd=folder, env=environment, check=True, timeout=60)
    subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, env=environment, check=True, timeout=60)

print("Managed window app: broker terminal grant, input/resize, detach/rebind, close cleanup and uncertain/cancelled thread lifecycle passed")

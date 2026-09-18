"""Focused native PTY acceptance for the managed window owner seam."""
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent))
import workspace

ROOT = Path(__file__).resolve().parents[1]

with workspace.fixture_workspace(unit_tests=False) as folder:
    shutil.copytree(ROOT / "tests/fixtures/window_native", folder / "src/tests/window_native")
    environment = workspace.database_environment(folder)
    subprocess.run([str(workspace.RUNTIME), "lint"], cwd=folder, env=environment, check=True, timeout=60)
    subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, env=environment, check=True, timeout=60)

print("Managed native window: same-owner PTY input/resize/close, completion finalization, duplicate-open and foreign-owner denial passed")

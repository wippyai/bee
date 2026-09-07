import subprocess
from workspace import RUNTIME, fixture_workspace

with fixture_workspace() as folder:
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True)
    subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, check=True)

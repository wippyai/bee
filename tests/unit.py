import os
import subprocess
from workspace import RUNTIME, fixture_workspace

with fixture_workspace(managed_gateway=True) as folder:
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True)
    # The Claude protocol fixture binary is bound explicitly by the carrier suite through its launch policy.
    environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"), "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
    # Hive tests register their own supervisor.
    subprocess.run([
        str(RUNTIME), "test", "--host", "bee:terminal",
        "--override", "bee.hive.host:supervisor_service:lifecycle.auto_start=false",
    ], cwd=folder, check=True, env=environment)

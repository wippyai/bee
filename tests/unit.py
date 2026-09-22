import os
import subprocess
from workspace import RUNTIME, fixture_workspace

with fixture_workspace(managed_gateway=True) as folder:
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True)
    # The Claude protocol fixture binary is bound explicitly by the carrier suite through its launch policy.
    fixture_bin = folder / "fixtures/harness/bin"
    # The native host environment resolves a bare executable name with a PATH
    # lookup (native/launch/environment.go). The shipped Claude window route
    # therefore depends on a host `claude`; the runner has none, so the
    # composition supplies the shipped fixture executable rather than the
    # developer's machine.
    environment = {
        **os.environ,
        "BEE_FIXTURE_BIN": str(fixture_bin),
        "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"),
        "PATH": str(fixture_bin) + os.pathsep + os.environ.get("PATH", ""),
    }
    # Hive tests register their own supervisor.
    subprocess.run([
        str(RUNTIME), "test", "--host", "bee:terminal",
        "--override", "bee.hive.host:supervisor_service:lifecycle.auto_start=false",
    ], cwd=folder, check=True, env=environment)

"""Run strict lint against the same disposable composition used by Lua tests."""
from pathlib import Path
import os
import subprocess

from workspace import RUNTIME, TEST_CACHE, database_environment, fixture_workspace


def environment(folder):
    # The carrier suite resolves its Claude fixture by name in the native host
    # PATH; every shard gets the binary, driver streams, and subsystem stores
    # from its own disposable fixture.
    fixture_bin = folder / "fixtures/harness/bin"
    fixture_home = folder / "host-home"
    (fixture_home / ".claude").mkdir(parents=True, exist_ok=True)
    # Locate observes only file existence; this empty file proves the ready
    # route without adding credential material to the fixture.
    (fixture_home / ".claude/.credentials.json").touch()
    databases = database_environment(folder)
    return {**{name: value for name, value in databases.items()
               if name.startswith("BEE_") and name.endswith("_DB")},
            **{name: value for name, value in os.environ.items() if name.startswith("BEE_TEST_")},
            "WIPPY_CACHE_DIR": str(Path(os.environ.get("WIPPY_CACHE_DIR") or TEST_CACHE).resolve()),
            "BEE_FIXTURE_BIN": str(fixture_bin),
            "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"),
            "BEE_AMBIENT_LIVE_PROVIDER": "none",
            "NO_COLOR": "",
            "HOME": str(fixture_home),
            "XDG_CONFIG_HOME": str(fixture_home / ".config"),
            "XDG_DATA_HOME": str(fixture_home / ".local/share"),
            "XDG_CACHE_HOME": str(fixture_home / ".cache"),
            "TMPDIR": str(folder),
            "LANG": "C.UTF-8",
            "PATH": str(fixture_bin) + os.pathsep + "/usr/bin:/bin"}


def fixture_lint(folder=None):
    if folder is not None:
        subprocess.run([str(RUNTIME), "lint", "--strict-any", "--set", "lua.type_system.strict_any=true"], cwd=folder, check=True, env=environment(folder))
        return
    with fixture_workspace(managed_gateway=True) as folder:
        fixture_lint(folder)


if __name__ == "__main__":
    fixture_lint()

"""Compile and draw every reference application against the public library.

The references in docs/reference/apps are documentation, not registered entries.
This check copies them into the Lua test composition, lints that composition
with the strict type system and runs the reference suite, so a reference cannot
drift from the library it demonstrates.
"""
import os
import subprocess

from unit import environment, report_shard, run_shard, test_entries
from workspace import RUNTIME, fixture_workspace


def main():
    entries = test_entries({"reference_apps"})
    with fixture_workspace(managed_gateway=True) as folder:
        subprocess.run([str(RUNTIME), "lint", "--ns", "bee.app.reference.test", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
                       cwd=folder, check=True, env={**os.environ, **environment(folder)})
        result = run_shard(0, folder, entries)
        report_shard(result)
        assert result[4], "the reference application suite failed"
    print(f"Reference applications: {len(entries)} entries compiled and drawn")


if __name__ == "__main__":
    main()

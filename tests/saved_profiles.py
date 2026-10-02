# SPDX-License-Identifier: MIT
"""Restart acceptance against the production saved-profile composition."""
import re
import shutil
import subprocess

from fixture_lint import environment, fixture_lint
from workspace import ROOT, RUNTIME, fixture_workspace


def setup(folder):
    shutil.copytree(ROOT / "tests/fixtures/saved_profiles", folder / "src/saved/profiles/probe")


def boot(folder, phase, node=None):
    args = [str(RUNTIME), "run", "--verbose", "--host", "bee.saved.profiles.probe:workers",
            "--", "saved-profiles-probe", phase]
    if node:
        args.append(node)
    result = subprocess.run(args, cwd=folder, env=environment(folder), capture_output=True, text=True, timeout=45)
    output = result.stdout + result.stderr
    if result.returncode or "service failed" in output.lower():
        raise AssertionError(f"{phase} saved profile boot failed:\n{output}")
    assert "SAVED_PROFILE_BINDING_PASS" in output, output
    return output


def main():
    with fixture_workspace(unit_tests=False) as folder:
        setup(folder)
        fixture_lint(folder)
        first = boot(folder, "first")
        match = re.search(r"SAVED_PROFILE_FIRST_BOOT_PASS node=([\w.-]+)", first)
        assert match, first
        print("SAVED_PROFILE_FIRST_BOOT_PASS", flush=True)
        second = boot(folder, "second", match[1])
        assert "SAVED_PROFILE_SECOND_BOOT_PASS node=" + match[1] + " actor=profile-reader" in second, second
        print("SAVED_PROFILE_SECOND_BOOT_PASS", flush=True)
    print("Saved profiles: production facade retains values, CAS revisions, tombstones and historical receipts across two boots")


if __name__ == "__main__":
    main()

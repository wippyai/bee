"""Prove group lifetime using the actual placement identity library and OS processes."""
import shutil
import subprocess
import tempfile
from pathlib import Path
from workspace import ROOT, RUNTIME, database_environment


def main():
    with tempfile.TemporaryDirectory(prefix="bee-identity-native-") as directory:
        folder = Path(directory)
        source = folder / "src"
        shutil.copytree(ROOT / "tests/fixtures/identity_native", source)
        shutil.copy2(ROOT / "modules/placement-native/src/service/identity.lua", source / "identity.lua")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        environment = database_environment(folder, BEE_IDENTITY_PATH="/usr/bin:/bin")
        subprocess.run([str(RUNTIME), "lint"], cwd=folder, env=environment, check=True, timeout=60)
        fake_bin = folder / "bin"
        fake_bin.mkdir()
        for label, script in (("lifetime", None), ("command failure", "exit 7\n"),
                              ("malformed table", "printf '1\\nbad\\n'\n"), ("empty table", "exit 0\n")):
            if script is not None:
                probe = fake_bin / "ps"
                probe.write_text("#!/bin/sh\n" + script)
                probe.chmod(0o700)
            case_environment = {**environment,
                                "BEE_IDENTITY_PATH": f"{fake_bin}:/usr/bin:/bin" if script else "/usr/bin:/bin",
                                "BEE_IDENTITY_EXPECTED": "unknown" if script else "lifetime"}
            case_environment["PATH"] = case_environment["BEE_IDENTITY_PATH"]
            result = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee.identity.probe:workers", "--", "identity-probe"],
                                    cwd=folder, env=case_environment, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            marker = "IDENTITY_GROUP_UNKNOWN_PASS" if script else "IDENTITY_GROUP_LIFETIME_PASS"
            if result.returncode or marker not in output:
                raise AssertionError(f"{label}: exit {result.returncode}: {output}")
            print(f"Native group identity: {label} passed")


if __name__ == "__main__":
    main()

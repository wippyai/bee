"""Run the governance publication precondition gate on a disposable registry.

Not part of make check until the runtime supports guarded durable publication.
No installed workspace or running Bee owner is touched.
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

from workspace import ROOT, RUNTIME


def main():
    with tempfile.TemporaryDirectory(prefix="bee-governance-runtime-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "tests/fixtures/governance_runtime", folder / "src")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
        subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=60)
        result = subprocess.run(
            [str(RUNTIME), "run", "--verbose", "--host", "bee.governance_probe:workers", "--", "governance-runtime-probe"],
            cwd=folder, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=30,
        )
        evidence = [line for line in result.stdout.splitlines() if "GOVERNANCE_STALE_APPLY_" in line]
        print("\n".join(evidence) if evidence else result.stdout)
        if result.returncode != 0 or "GOVERNANCE_STALE_APPLY_REFUSED" not in result.stdout:
            raise SystemExit("Governance runtime gate failed: guarded publication is not established")


if __name__ == "__main__":
    main()

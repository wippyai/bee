"""MIT. Isolated executable proof of the ephemeral overlay owner boundary."""
import shutil
import subprocess
import tempfile
from pathlib import Path

from workspace import ROOT, RUNTIME


def main():
    with tempfile.TemporaryDirectory(prefix="bee-governance-overlay-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "tests/fixtures/governance_overlay", folder / "src")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
        subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=60)
        result = subprocess.run(
            [str(RUNTIME), "run", "--verbose", "--host", "bee.governance_overlay_probe:workers", "--", "governance-overlay-probe"],
            cwd=folder, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=30,
        )
        if result.returncode != 0 or "GOVERNANCE_OVERLAY_OWNER_PASS" not in result.stdout:
            print(result.stdout)
            raise SystemExit("Governance overlay owner gate failed")
        print("GOVERNANCE_OVERLAY_OWNER_PASS: generation conflict, ownership, permissions, explicit cleanup, no durable history")


if __name__ == "__main__":
    main()

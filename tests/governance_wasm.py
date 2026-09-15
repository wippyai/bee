"""MIT. Actual WASI mount read, read-only, traversal and symlink escape checks."""
import shutil
import subprocess
import tempfile
from pathlib import Path

from workspace import ROOT, RUNTIME


def main():
    with tempfile.TemporaryDirectory(prefix="bee-governance-wasm-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "tests/fixtures/governance_wasm", folder / "src")
        (folder / "data").mkdir()
        (folder / "data/input.txt").write_text("mount-ok")
        (folder / "outside.txt").write_text("outside-secret")
        (folder / "data/link.txt").symlink_to(folder / "outside.txt")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
        subprocess.run([str(RUNTIME), "lint"], cwd=folder, check=True, timeout=60)
        result = subprocess.run(
            [str(RUNTIME), "run", "--verbose", "--host", "bee.governance_wasm_probe:workers", "--", "governance-wasm-probe"],
            cwd=folder, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=30,
        )
        if result.returncode != 0 or "GOVERNANCE_WASM_FS_PASS" not in result.stdout:
            print(result.stdout)
            raise SystemExit("Governance WASM filesystem gate failed")
        assert (folder / "data/input.txt").read_text() == "mount-ok"
        assert (folder / "outside.txt").read_text() == "outside-secret"
        print("GOVERNANCE_WASM_FS_PASS: admitted read, read-only, traversal and symlink refusal")


if __name__ == "__main__":
    main()

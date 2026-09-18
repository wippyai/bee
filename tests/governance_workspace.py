"""MIT. Headless authoring trait route on one retained migrated SQLite store."""
import shutil
import sqlite3
import subprocess
import tempfile
import yaml
from pathlib import Path
from workspace import ROOT, RUNTIME, database_environment


def main():
    with tempfile.TemporaryDirectory(prefix="bee-governance-workspace-") as directory:
        folder = Path(directory)
        for name in ("governance", "sync", "persist"):
            shutil.copytree(ROOT / "src" / name, folder / "src" / name)
        sync_index = folder / "src/sync/_index.yaml"
        sync_document = yaml.safe_load(sync_index.read_text())
        sync_document["entries"] = [entry for entry in sync_document["entries"] if entry["name"] in {"bounds", "canonical"}]
        sync_index.write_text(yaml.safe_dump(sync_document, sort_keys=False))
        shutil.copytree(ROOT / "src/threads/records", folder / "src/records")
        shutil.copytree(ROOT / "tests/fixtures/governance_workspace", folder / "src/probe")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
        environment = database_environment(folder)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=folder, env=environment, check=True, timeout=60)
        for phase in ("FIRST", "SECOND"):
            result = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee.governance_workspace_probe:workers", "--", "governance-workspace-probe"], cwd=folder, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40)
            marker = "GOVERNANCE_WORKSPACE_" + phase + "_BOOT_PASS"
            if result.returncode or marker not in result.stdout or "service failed" in result.stdout:
                print(result.stdout)
                raise SystemExit("Governance authoring acceptance failed in " + phase)
            print(marker)
        with sqlite3.connect(folder / "governance.db") as connection:
            assert connection.execute("SELECT id FROM bee_governance_migrations ORDER BY id").fetchall() == [(1,)]
            assert sorted(connection.execute("SELECT content_base64 FROM bee_governance_snapshot_files").fetchall()) == [("AP9hc3NldA==",), ("dXBkYXRlZA==",)], "frozen files followed mutable edit/removal"
            assert connection.execute("SELECT COUNT(*) FROM bee_governance_receipts").fetchone() == (7,), "refusals or retries created receipts"
            # Fault injection touches only this disposable fixture's content,
            # never an applied migration or a user's workspace database.
            connection.execute("UPDATE bee_governance_snapshot_files SET content_base64 = 'AAAA' WHERE content_base64 = 'AP9hc3NldA=='")
            connection.commit()
        corrupt = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee.governance_workspace_probe:workers", "--", "governance-workspace-probe", "corrupted-snapshot"], cwd=folder, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40)
        if corrupt.returncode or "GOVERNANCE_WORKSPACE_CORRUPTION_REFUSED" not in corrupt.stdout:
            print(corrupt.stdout)
            raise SystemExit("Corrupt frozen content was not refused")
        print("GOVERNANCE_WORKSPACE_CORRUPTION_REFUSED")
        print("Governance authoring: authenticated dispatch, binary files, CAS, immutable freeze receipts, migration and restart passed")


if __name__ == "__main__":
    main()

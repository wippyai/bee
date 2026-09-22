"""Headless node metadata + ledger acceptance on one retained SQLite database."""
import shutil
import subprocess
import tempfile
from pathlib import Path
from workspace import ROOT, RUNTIME, database_environment


def main():
    with tempfile.TemporaryDirectory(prefix="bee-sync-module-") as directory:
        folder = Path(directory)
        for name in ("node", "sync", "persist"):
            shutil.copytree(ROOT / "src" / name, folder / "src" / name)
        shutil.copytree(ROOT / "modules/bee-threads/src/records", folder / "src/records")
        # Only the pure appearance value library; no desktop actor or terminal.
        appearance = folder / "src/appearance"
        appearance.mkdir()
        shutil.copy2(ROOT / "src/ui/appearance.lua", appearance / "appearance.lua")
        (appearance / "_index.yaml").write_text("version: '1.0'\nnamespace: bee.desktop\nentries:\n- name: appearance\n  kind: library.lua\n  source: file://appearance.lua\n")
        shutil.copytree(ROOT / "tests/fixtures/sync_module", folder / "src/probe")
        (folder / "wippy.lock").write_text("directories:\n  modules: .wippy\n  src: ./src\n")
        (folder / ".wippy.yaml").write_text("version: '1.0'\nshutdown:\n  timeout: 2s\n")
        environment = database_environment(folder)
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=folder, check=True, timeout=60, env=environment)
        for phase in ("FIRST", "SECOND"):
            result = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee.sync_probe:workers", "--", "sync-probe"],
                cwd=folder, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=40)
            marker = "NODE_SYNC_" + phase + "_BOOT_PASS"
            if result.returncode or marker not in result.stdout or "service failed" in result.stdout:
                print(result.stdout)
                raise SystemExit("Node sync acceptance failed in " + phase)
            print(marker)
        print("Node sync: public dispatch, permissions, CAS, replay, ledger catch-up and same-database restart passed")


if __name__ == "__main__":
    main()

"""Source/pack proof of protected admission refresh through the actual broker."""
from pathlib import Path
import shutil
import subprocess
import tempfile

from workspace import ROOT, RUNTIME, database_environment, deployment_copy, pack_deployment


def run():
    for packed in (False, True):
        with tempfile.TemporaryDirectory(prefix="bee-app-admission-") as directory:
            folder = Path(directory)
            project = folder / "project"
            shutil.copytree(ROOT / "src", project / "src")
            shutil.copytree(ROOT / "modules", project / "modules")
            shutil.copytree(ROOT / "tests/fixtures/app_admission", project / "src/probe")
            shutil.copy2(ROOT / ".wippy.yaml", project / ".wippy.yaml")
            # Carry the production embed declaration so the pack embeds the corpus.
            shutil.copy2(ROOT / "wippy.yaml", project / "wippy.yaml")
            shutil.copy2(ROOT / "wippy.lock", project / "wippy.lock")
            if not packed:
                subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true",
                                "--set", "lua.type_system.strict=true"], cwd=project, check=True)
            package = project / "admission-deployment"
            if packed:
                pack_deployment(project, package)
            if packed:
                deployment_copy(package, folder)
            args = [str(RUNTIME), "--console", "run"]
            args += ["app-admission-probe", "--host", "bee:workers", "--set", f"registry.history_path={folder}/registry.db"]
            try:
                result = subprocess.run(args, cwd=folder if packed else project, capture_output=True,
                                        text=True, timeout=35, env=database_environment(folder))
            except subprocess.TimeoutExpired as error:
                print(error.stdout, error.stderr, flush=True)
                raise
            output = result.stdout + result.stderr
            assert result.returncode == 0 and "BEE_APP_ADMISSION_COMPLETE" in output, output
    print("Source/pack: unbound denial, admission refresh, scope replacement, revocation, invalid policy/declaration recovery and retained producers", flush=True)


if __name__ == "__main__":
    run()

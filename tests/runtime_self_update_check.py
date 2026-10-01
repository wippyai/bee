"""Run the self-update, offline restore and newer-baseline tests in Bee's pinned runtime."""
import os
import shutil
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = "github.com/wippyai/runtime"
TESTS = (
    "TestDependencyHandler_DeploymentRootSelfUpdateRepairsStoredResolution",
    "TestDependencyHandler_PersistedResolutionBootRollbackRedoAndLongHistory",
    "TestDependencyHandler_RootApplicationUpdatePreservesNestedDependencyRoots",
)


def main():
    result = subprocess.run(
        ["go", "-C", str(ROOT / "native"), "list", "-m", "-f", "{{.Dir}}", RUNTIME],
        check=True, capture_output=True, text=True,
    )
    module = Path(result.stdout.strip())
    required = module / "boot/deps/hub/dependency_boot_test.go"
    if not required.is_file() or not (module / "boot/deps/hub/root_application_update_test.go").is_file():
        raise SystemExit(f"pinned runtime {module} lacks the root self-update continuity tests")
    env = dict(os.environ, GOWORK="off", GOTOOLCHAIN="go1.27.0")
    pattern = "^(" + "|".join(TESTS) + ")$"
    subprocess.run(["go", "test", "./boot/deps/hub", "-run", pattern, "-count=1"],
                   cwd=module, env=env, check=True)
    with tempfile.TemporaryDirectory(prefix="bee-runtime-selfroot-") as directory:
        copied = Path(directory) / "runtime"
        shutil.copytree(module, copied)
        (copied / "cmd/app").chmod(0o700)
        (copied / "go.mod").chmod(0o600)
        (copied / "go.sum").chmod(0o600)
        shutil.copy2(ROOT / "tests/runtime_seeded_root_test.go", copied / "cmd/app/bee_seeded_root_test.go")
        # Dependency-module replacements are ignored by Bee's native build.
        # The module zip also omits the nested third_party/ansi module.
        subprocess.run(["go", "mod", "edit", "-dropreplace=github.com/charmbracelet/x/ansi"],
                       cwd=copied, env=env, check=True)
        subprocess.run(["go", "test", "-mod=mod", "./cmd/app",
                        "-run", "^TestBeeSeededStandaloneRootVisibleInLuaSnapshot$", "-count=1"],
                       cwd=copied, env=env, check=True)
    print("Pinned runtime proves standalone root visibility, cached history restore, nested roots, and newer-baseline reconciliation.")


if __name__ == "__main__":
    main()

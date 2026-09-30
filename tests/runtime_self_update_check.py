"""Run the self-update, offline restore and newer-baseline tests in Bee's pinned runtime."""
import os
from pathlib import Path
import subprocess


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
    print("Pinned runtime proves registry-history restore from cached artifacts, nested root preservation, and newer-baseline reconciliation.")


if __name__ == "__main__":
    main()

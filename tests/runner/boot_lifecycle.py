"""Exercise Bee's declared completion dependencies in isolated native boots."""
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

import yaml

REPO = Path(__file__).resolve().parents[2]


def run(toolchain, failing):
    root = REPO / "tests/.wippy/boot-lifecycle" / uuid.uuid4().hex
    application = root / "application"
    shutil.copytree(REPO / "src", application / "src")
    shutil.copy2(REPO / "wippy.yaml", application)
    workspace = root / "workspace"
    source = workspace / "lua"
    source.mkdir(parents=True)
    fixture = REPO / "tests/lua/process"
    document = yaml.safe_load((fixture / "_index.yaml").read_text())
    document["entries"] = [entry for entry in document["entries"] if entry["name"] in
                           ("boot_lifecycle_test", "lifecycle_gate", "lifecycle_observer")]
    for entry in document["entries"]:
        if entry["name"] == "boot_lifecycle_test":
            entry["meta"]["type"] = "test"
        if failing and entry["name"] == "lifecycle_gate":
            entry["method"] = "failing_completion"
    document["entries"].extend([
        {"name": "dependency", "kind": "ns.dependency", "component": "bee/bee", "version": "*"},
        {"name": "lifecycle_policy", "kind": "security.policy",
         "policy": {"actions": ["*"], "resources": "*", "effect": "allow"}},
    ])
    (source / "_index.yaml").write_text(yaml.safe_dump(document, sort_keys=False))
    shutil.copy2(fixture / "boot_lifecycle_test.lua", source)
    index_path = application / "src/gov/service/_index.yaml"
    index = yaml.safe_load(index_path.read_text())
    recovery = next(entry for entry in index["entries"] if entry["name"] == "recovery_service")
    recovery["process"] = "bee.tests.process:lifecycle_gate"
    recovery["lifecycle"]["security"] = {"policies": ["bee.tests.process:lifecycle_policy"]}
    index_path.write_text(yaml.safe_dump(index, sort_keys=False))
    shutil.copy2(REPO / "tests/wippy.lock", workspace)
    (workspace / ".wippy").mkdir()
    (workspace / ".wippy/vendor").symlink_to(REPO / "tests/.wippy/vendor", target_is_directory=True)
    (workspace / ".wippy.yaml").write_text(yaml.safe_dump({
        "version": "1.0", "workspace": {"replacements": {"bee/bee": str(application)}},
        "cluster": {"name": "boot-lifecycle-" + root.name},
    }))
    home = root / "home"
    home.mkdir()
    environment = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8",
                   "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
                   "XDG_CACHE_HOME": str(home / ".cache"), "BEE_DB": str(root / "bee.db"),
                   "BEE_ENV": str(root / "bee.env"), "GOMAXPROCS": "2"}
    result = subprocess.run([str(toolchain), "-c", "test", "--host", "bee:terminal",
                             "--set", "security.strict_mode=true", "-o", "bee:terminal:hide_logs=false",
                             "test", "bee.tests.process:boot_lifecycle_test"],
                            cwd=workspace, env=environment, text=True, capture_output=True, timeout=30)
    output = result.stdout + result.stderr
    log = root / "output.log"
    log.write_text(output)
    if failing:
        assert result.returncode == 1, output
        assert 'boot gate "bee.gov.service:recovery_service" failed' in output, output
        assert "injected boot completion failure" in output, output
        assert "Native boot completion lifecycle" not in output, output
        print("PASS: failing_completion fails boot before the test command runs")
    else:
        assert result.returncode == 0, output
        assert "starts dependents only after the held recovery gate completes" in output, output
        print("PASS: boot_lifecycle_test holds Threads, Node and Hive until recovery completes")
    print("Proof:", log.relative_to(REPO))


def main():
    toolchain = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REPO / ".wippy/bin/wippy"
    run(toolchain, False)
    run(toolchain, True)


if __name__ == "__main__":
    main()

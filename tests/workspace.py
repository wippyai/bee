"""Compose test-only entries outside the production source and registry history."""
from contextlib import contextmanager
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()

@contextmanager
def fixture_workspace(presenter_probe=False):
    with tempfile.TemporaryDirectory(prefix="bee-fixtures-") as temporary:
        folder = Path(temporary)
        shutil.copytree(ROOT / "src", folder / "src")
        if presenter_probe:
            # Test-only incarnation marker proves an identical screen was drawn
            # by a fresh process. No diagnostics or test flags enter the core pack.
            presenter = folder / "src/core/terminal/main.lua"
            text = presenter.read_text()
            label = '"Workspace " .. workspace_id:sub(1, 8)'
            assert label in text
            text = text.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)')
            anchor = 'local action = bindings.action('
            assert anchor in text
            text = text.replace(anchor, 'if event.key_type == "f10" then error("Injected presenter failure") end\n                ' + anchor)
            presenter.write_text(text)
        shutil.copytree(ROOT / "tests/lua", folder / "src/tests")
        shutil.copytree(ROOT / "examples/fixtures", folder / "src/fixtures")
        shutil.copy2(ROOT / ".wippy.yaml", folder / ".wippy.yaml")
        lock = yaml.safe_load((ROOT / "wippy.lock").read_text())
        lock.setdefault("modules", [])
        lock["modules"] += yaml.safe_load((ROOT / "tests/dependencies.yaml").read_text())["modules"]
        (folder / "wippy.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
        vendor = folder / ".wippy/vendor/wippy"
        vendor.mkdir(parents=True)
        missing_dependency = False
        for module in lock["modules"]:
            prefix = module["name"].split("/")[1] + "-" + str(module["version"])
            packages = list((ROOT / ".wippy/vendor/wippy").glob(prefix + "*.wapp"))
            if not packages:
                missing_dependency = True
            for package in packages:
                shutil.copy2(package, vendor / package.name)
        host = folder / "src/_index.yaml"
        document = yaml.safe_load(host.read_text())
        document["entries"].append({"name": "test_dependency", "kind": "ns.dependency", "component": "wippy/test", "version": "0.4.17"})
        for entry in document["entries"]:
            if entry["name"] == "application_admission":
                entry["bindings"] += [{"definition_id": identity, "policies": []} for identity in ["bee.apps:welcome", "bee.apps:palette"]]
        host.write_text(yaml.safe_dump(document, sort_keys=False))
        if missing_dependency:
            subprocess.run([str(RUNTIME), "install"], cwd=folder, check=True)
        yield folder


def pack_fixture(folder, destination):
    """Exclude all test entries by metadata so a new suite cannot leak into a pack."""
    excluded = {"bee:test_dependency"}
    for index in (folder / "src").rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        for entry in document["entries"]:
            if entry.get("meta", {}).get("type") == "test":
                excluded.add(f'{document["namespace"]}:{entry["name"]}')
    args = [str(RUNTIME), "pack", "--exclude-ns", "wippy.test"]
    for identity in sorted(excluded):
        args += ["--exclude", identity]
    subprocess.run(args + [str(destination)], cwd=folder, check=True)

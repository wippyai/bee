"""Compose test-only entries outside the production source and registry history."""
from contextlib import contextmanager
from pathlib import Path
import os
import shutil
import socket
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()


def managed_gateway_address():
    """Select an available ephemeral loopback address for one composition."""
    # http.service accepts an address rather than a pre-bound socket, so the
    # socket closes before startup and cannot reserve it permanently. The
    # copied host, policy and listener all retain the selected address,
    # preventing concurrent fixtures from answering one another's readiness
    # probes on the historical shared port.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return f"127.0.0.1:{listener.getsockname()[1]}"


def configure_managed_gateway(folder, address=None):
    """Point this copied managed composition at one isolated loopback address."""
    selected = address or managed_gateway_address()
    host = folder / "src/_index.yaml"
    document = yaml.safe_load(host.read_text())
    endpoint = next((entry for entry in document["entries"] if entry["name"] == "gateway_endpoint"), None)
    readiness = next((entry for entry in document["entries"] if entry["name"] == "gateway_readiness_policy"), None)
    assert endpoint is not None and readiness is not None
    endpoint["data"]["address"] = selected
    resources = readiness["policy"]["resources"]
    original = "http://127.0.0.1:18790/ready"
    assert original in resources
    resources[resources.index(original)] = f"http://{selected}/ready"
    host.write_text(yaml.safe_dump(document, sort_keys=False))
    listeners = []
    for index in (folder / "src").rglob("_index.yaml"):
        entry_document = yaml.safe_load(index.read_text())
        if entry_document.get("namespace") != "bee.managed":
            continue
        listener = next((entry for entry in entry_document["entries"] if entry["name"] == "listener"), None)
        if listener is not None:
            listener["addr"] = selected
            index.write_text(yaml.safe_dump(entry_document, sort_keys=False))
            listeners.append(index)
    assert len(listeners) == 1
    return selected

def database_environment(directory, **overrides):
    """Keep every booted subsystem store inside the fixture's disposable root."""
    root = Path(directory)
    names = ("workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node")
    return {**os.environ, **{f"BEE_{name.upper()}_DB": str(root / f"{name}.db") for name in names}, **overrides}


@contextmanager
def fixture_workspace(presenter_probe=False, managed_gateway=False, unit_tests=True):
    with tempfile.TemporaryDirectory(prefix="bee-fixtures-") as temporary:
        folder = Path(temporary)
        shutil.copytree(ROOT / "src", folder / "src")
        if presenter_probe:
            # Test-only incarnation marker proves an identical screen was drawn
            # by a fresh process. No diagnostics or test flags enter the core pack.
            presenter = folder / "src/core/terminal/main.lua"
            text = presenter.read_text()
            label = '"Workspace " .. names.label(workspace_id)'
            assert label in text
            text = text.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)')
            anchor = 'local action = bindings.action('
            assert anchor in text
            text = text.replace(anchor, 'if event.key_type == "f10" then error("Injected presenter failure") end\n                ' + anchor)
            presenter.write_text(text)
        if managed_gateway and not unit_tests:
            raise ValueError("The managed gateway belongs to the unit-test composition")
        if unit_tests:
            shutil.copytree(ROOT / "tests/lua", folder / "src/tests")
        else:
            (folder / "src/tests").mkdir()
        # Managed harness tests own their loopback listener. Desktop proofs
        # must retain the default composition's no-listener boundary.
        if not managed_gateway:
            shutil.rmtree(folder / "src/tests/managed", ignore_errors=True)
        else:
            configure_managed_gateway(folder)
        shutil.copytree(ROOT / "examples/fixtures", folder / "src/fixtures")
        shutil.copytree(ROOT / "tests/fixtures/drivers", folder / "fixtures/drivers")
        shutil.copytree(ROOT / "tests/fixtures/harness", folder / "fixtures/harness")
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
                entry["bindings"] += [{"definition_id": identity, "policies": ["bee:ordinary_app_subsystem_boundary"]} for identity in ["bee.apps:welcome", "bee.apps:palette"]]
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
            meta = entry.get("meta", {})
            if meta.get("type") in {"test", "test_support"} or meta.get("test_support") is True:
                excluded.add(f'{document["namespace"]}:{entry["name"]}')
    args = [str(RUNTIME), "pack", "--exclude-ns", "wippy.test"]
    for identity in sorted(excluded):
        args += ["--exclude", identity]
    subprocess.run(args + [str(destination)], cwd=folder, check=True)

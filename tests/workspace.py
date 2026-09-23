"""Compose test-only entries outside the production source and registry history."""
from contextlib import contextmanager
from pathlib import Path
import atexit
import hashlib
import json
import os
import shutil
import socket
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()


def registry_entries(folder, names):
    """Find uniquely named production entries across the split manifests."""
    wanted = set(names)
    found = {}
    documents = {}
    roots = [folder / "src"]
    modules = folder / "modules"
    if modules.exists():
        roots.append(modules)
    for root in roots:
        for index in root.rglob("_index.yaml"):
            document = yaml.safe_load(index.read_text())
            documents[index] = document
            for entry in document.get("entries", []):
                name = entry.get("name")
                if name not in wanted:
                    continue
                assert name not in found, f"duplicate registry entry {name}"
                found[name] = (index, entry)
    assert set(found) == wanted, f"missing registry entries {sorted(wanted - set(found))}"
    return found, documents


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
    found, documents = registry_entries(folder, {"gateway_endpoint", "readiness_policy"})
    endpoint = found["gateway_endpoint"][1]
    readiness = found["readiness_policy"][1]
    assert yaml.safe_load(found["readiness_policy"][0].read_text())["namespace"] == "bee.gateway.security"
    endpoint["data"]["address"] = selected
    assert readiness["kind"] == "security.policy.expr"
    readiness["policy"]["expression"] = (
        '(action == "http_client.private_ip" && resource == "127.0.0.1") || '
        f'(action == "http_client.request" && resource == "http://{selected}/ready")'
    )
    for index in {found["gateway_endpoint"][0], found["readiness_policy"][0]}:
        index.write_text(yaml.safe_dump(documents[index], sort_keys=False))
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
    names = ("workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "sync")
    return {**os.environ, **{f"BEE_{name.upper()}_DB": str(root / f"{name}.db") for name in names}, **overrides}


@contextmanager
def fixture_workspace(presenter_probe=False, managed_gateway=False, unit_tests=True):
    with tempfile.TemporaryDirectory(prefix="bee-fixtures-") as temporary:
        folder = Path(temporary)
        shutil.copytree(ROOT / "src", folder / "src")
        shutil.copytree(ROOT / "modules", folder / "modules")
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
            # This test-support copy overrides homes while exercising the
            # component's current materialization source; it never enters a
            # production source tree or assembled pack.
            shutil.copy2(ROOT / "modules/placement-native/src/service/materialization.lua",
                         folder / "src/tests/placement_publication/materialization.lua")
        else:
            (folder / "src/tests").mkdir()
        # Managed harness tests own their loopback listener. Desktop proofs
        # must retain the default composition's no-listener boundary.
        if not managed_gateway:
            shutil.rmtree(folder / "src/tests/managed", ignore_errors=True)
        else:
            configure_managed_gateway(folder)
        shutil.copytree(ROOT / "tests/fixtures/desktop_apps", folder / "src/fixtures")
        shutil.copytree(ROOT / "tests/fixtures/drivers", folder / "fixtures/drivers")
        shutil.copytree(ROOT / "tests/fixtures/harness", folder / "fixtures/harness")
        shutil.copy2(ROOT / ".wippy.yaml", folder / ".wippy.yaml")
        # Carry the production embed declaration so a packed fixture embeds the
        # offline documentation corpus read-only instead of resolving a project
        # directory relative to the packed run's working directory.
        shutil.copy2(ROOT / "wippy.yaml", folder / "wippy.yaml")
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
        host.write_text(yaml.safe_dump(document, sort_keys=False))
        found, documents = registry_entries(folder, {"application_admission"})
        admission_index, admission = found["application_admission"]
        admission["bindings"] += [{"definition_id": identity, "policies": ["bee:ordinary_app_subsystem_boundary"]} for identity in ["bee.apps:welcome", "bee.apps:palette"]]
        admission_index.write_text(yaml.safe_dump(documents[admission_index], sort_keys=False))
        if missing_dependency:
            subprocess.run([str(RUNTIME), "install"], cwd=folder, check=True)
        yield folder


def pack_deployment(folder, destination, excluded=()):
    """Assemble a source-free deployment of one composition.

    Bee is several physical modules, so a portable launch is a lock that pins
    one pack per module, the bee/bee root among them, beside those packs in
    its vendor directory; build/portable-pack.sh assembles the same layout for
    the product. Modules that tests/dependencies.yaml adds for test suites
    never enter the deployment."""
    folder, destination = Path(folder), Path(destination)
    version = next(pack["version"] for pack in json.loads((ROOT / "wippy.build.json").read_text())["application"]["packs"]
                   if pack["module"] == "bee/bee")
    test_modules = {module["name"] for module in yaml.safe_load((ROOT / "tests/dependencies.yaml").read_text())["modules"]}
    with tempfile.TemporaryDirectory(prefix="bee-deployment-") as temporary:
        source = Path(temporary) / "source"
        for name in ("src", "modules", ".wippy/vendor"):
            if (folder / name).exists():
                shutil.copytree(folder / name, source / name, symlinks=True)
        for name in ("wippy.yaml", ".wippy.yaml", "wippy.lock"):
            shutil.copy2(folder / name, source / name)
        # bee/bee is implicit in editable development; --module needs it named.
        lock = yaml.safe_load((source / "wippy.lock").read_text())
        selected = [module for module in lock.get("modules", []) if module["name"] not in test_modules]
        lock["modules"] = [{"name": "bee/bee", "version": version, "root": True}] + lock.get("modules", [])
        (source / "wippy.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
        configuration = yaml.safe_load((source / ".wippy.yaml").read_text())
        configuration["workspace"]["replacements"]["bee/bee"] = "."
        (source / ".wippy.yaml").write_text(yaml.safe_dump(configuration, sort_keys=False))
        # A repacked composition replaces its earlier deployment.
        shutil.rmtree(destination, ignore_errors=True)
        vendor = destination / ".wippy/vendor/bee"
        vendor.mkdir(parents=True)
        (destination / "empty").mkdir()
        pinned = []
        for module in [{"name": "bee/bee", "version": version}] + selected:
            organization, name = module["name"].split("/")
            assert organization == "bee", f"deployment module {module['name']} is outside Bee"
            pack = vendor / f"{name}-{module['version']}.wapp"
            args = [str(RUNTIME), "pack", "--silent", "--module", module["name"], "--exclude-ns", "wippy.test"]
            for identity in sorted(excluded):
                args += ["--exclude", identity]
            subprocess.run(args + [str(pack)], cwd=source, check=True)
            entry = {"name": module["name"], "version": module["version"],
                     "hash": "sha256:" + hashlib.sha256(pack.read_bytes()).hexdigest()}
            if module["name"] == "bee/bee":
                entry["root"] = True
            pinned.append(entry)
    (destination / "wippy.lock").write_text(yaml.safe_dump(
        {"directories": {"modules": ".wippy", "src": "./empty"}, "modules": pinned}, sort_keys=False))
    (destination / ".wippy.yaml").write_text(yaml.safe_dump(
        {"version": "1.0", "registry": {"enable_history": True, "history_type": "sqlite", "history_path": ".wippy/registry.db"},
         "shutdown": {"timeout": "3s"}}, sort_keys=False))
    return destination


def pack_fixture(folder, destination):
    """Exclude all test entries by metadata so a new suite cannot leak into a pack."""
    excluded = {"bee:test_dependency"}
    for index in (folder / "src").rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        for entry in document["entries"]:
            meta = entry.get("meta", {})
            if meta.get("type") in {"test", "test_support"} or meta.get("test_support") is True:
                excluded.add(f'{document["namespace"]}:{entry["name"]}')
    return pack_deployment(folder, destination, excluded)


_product_deployment = None


def product_deployment():
    """This checkout's development deployment, assembled once per test process."""
    global _product_deployment
    if _product_deployment is None:
        holder = Path(tempfile.mkdtemp(prefix="bee-product-deployment-"))
        atexit.register(shutil.rmtree, holder, True)
        _product_deployment = pack_deployment(ROOT, holder / "deployment")
    return _product_deployment


def deployment_copy(deployment, directory):
    """Place a deployment in the disposable working directory of one launch."""
    shutil.copytree(deployment, directory, symlinks=True, dirs_exist_ok=True)
    return Path(directory)

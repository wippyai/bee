"""Actual broker-spawn acceptance for the private managed native window app."""
from pathlib import Path
import shutil
import subprocess
import sys
import yaml

sys.path.insert(0, str(Path(__file__).parent))
import workspace

ROOT = Path(__file__).resolve().parents[1]

with workspace.fixture_workspace(unit_tests=False) as folder:
    shutil.copytree(ROOT / "tests/fixtures/managed_window_app", folder / "src/tests/managed_window_app")
    sessions_index = folder / "modules/sessions/src/binding/_index.yaml"
    sessions_document = yaml.safe_load(sessions_index.read_text())
    for entry in sessions_document["entries"]:
        if entry["name"] == "catalog_binding":
            entry["contracts"][0]["default"] = False
    sessions_index.write_text(yaml.safe_dump(sessions_document, sort_keys=False))
    host = folder / "modules/harness/src/launch/_index.yaml"
    document = yaml.safe_load(host.read_text())
    activation = next(entry for entry in document["entries"] if entry["name"] == "harness_activation")
    activation["data"]["bindings"].append("bee.managed.window.fixture:binding")
    host.write_text(yaml.safe_dump(document, sort_keys=False))
    facade_index = folder / "modules/harness/src/binding/_index.yaml"
    facade_document = yaml.safe_load(facade_index.read_text())
    profile_facade = next(entry for entry in facade_document["entries"] if entry["name"] == "call")
    profile_facade["modules"].append("time")
    facade_index.write_text(yaml.safe_dump(facade_document, sort_keys=False))
    facade_source = folder / "modules/harness/src/binding/method.lua"
    profile_source = facade_source.read_text().replace(
        'local system = require("system")',
        'local system = require("system")\nlocal time = require("time")').replace(
        'local function handle(raw: unknown): Result\n',
        'local function handle(raw: unknown): Result\n'
        '    if type(raw) == "table" and raw.operation == "list" and raw.workspace_id == string.rep("a", 32) then time.sleep("1500ms") end\n')
    facade_source.write_text(profile_source)
    admission_source = folder / "modules/harness/src/launch/admission.lua"
    admission_source.write_text(admission_source.read_text().replace(
        '    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,\n',
        '    if request.workspace_id == string.rep("a", 32) then time.sleep("1s") end\n'
        '    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,\n'))
    security_index = folder / "modules/harness/src/security/_index.yaml"
    security_index.write_text(security_index.read_text().replace(
        'resource == "bee.sessions.binding:catalog_binding"',
        'resource == "bee.sessions.binding:catalog_binding" || resource == "bee.managed.window.fixture:catalog_owner"'))
    environment = workspace.database_environment(folder)
    # The product composition is linted by `make lint`; this proof lints its fixture
    # and the harness entries it rewrites.
    subprocess.run([str(workspace.RUNTIME), "lint", "--ns", "bee.managed.window.fixture,bee.harness.binding,bee.harness.profiles,bee.harness.launch"],
                   cwd=folder, env=environment, check=True, timeout=60)
    selected = ["test", "bee.managed.window.fixture:checkpoint_ack_test"] if "--checkpoint-only" in sys.argv else []
    subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal", *selected], cwd=folder, env=environment, check=True, timeout=60)

print("Managed window app: responsive discovery/activation, cancellation cleanup, broker terminal grant, input/resize, detach/rebind and truthful receipts passed")

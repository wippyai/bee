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
    host = folder / "src/harness/host/_index.yaml"
    document = yaml.safe_load(host.read_text())
    activation = next(entry for entry in document["entries"] if entry["name"] == "harness_activation")
    activation["data"]["bindings"].append("bee.managed_window_fixture:binding")
    host.write_text(yaml.safe_dump(document, sort_keys=False))
    profiles_index = folder / "modules/harness/src/profiles/_index.yaml"
    profiles_document = yaml.safe_load(profiles_index.read_text())
    profile_service = next(entry for entry in profiles_document["entries"] if entry["name"] == "service")
    profile_service["modules"].append("time")
    profiles_index.write_text(yaml.safe_dump(profiles_document, sort_keys=False))
    profiles_service = folder / "modules/harness/src/profiles/service.lua"
    profile_source = profiles_service.read_text().replace(
        'local system = require("system")',
        'local system = require("system")\nlocal time = require("time")').replace(
        'function M.call(raw: unknown): Result\n',
        'function M.call(raw: unknown): Result\n'
        '    if type(raw) == "table" and raw.operation == "list" and raw.workspace_id == string.rep("a", 32) then time.sleep("1500ms") end\n')
    profiles_service.write_text(profile_source)
    admission_source = folder / "modules/harness/src/launch/admission.lua"
    admission_source.write_text(admission_source.read_text().replace(
        '    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,\n',
        '    if request.workspace_id == string.rep("a", 32) then time.sleep("1s") end\n'
        '    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,\n'))
    environment = workspace.database_environment(folder)
    subprocess.run([str(workspace.RUNTIME), "lint"], cwd=folder, env=environment, check=True, timeout=60)
    subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, env=environment, check=True, timeout=60)

print("Managed window app: responsive discovery/activation, cancellation cleanup, broker terminal grant, input/resize, detach/rebind and truthful receipts passed")

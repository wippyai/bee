"""Check the small production graph without walking legacy or local state."""
from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
assert not (ROOT / "legacy").exists(), "Keep the legacy archive outside the repository"
lock = yaml.safe_load((ROOT / "wippy.lock").read_text())
assert lock["directories"]["src"] == "./src", "Production must load only src/"
assert not lock.get("modules"), "Core boot must not depend on fixture/test packages"
config = yaml.safe_load((ROOT / ".wippy.yaml").read_text())
assert not config.get("workspace", {}).get("replacements"), "Review dependency replacements before admitting them"
entries = {}
locations = {}
for path in (ROOT / "src").rglob("_index.yaml"):
    document = yaml.safe_load(path.read_text())
    for entry in document["entries"]:
        identity = f'{document["namespace"]}:{entry["name"]}'
        assert identity not in entries, f"Duplicate registry identity {identity}"
        entries[identity] = entry
        locations[identity] = path.relative_to(ROOT / "src")
        for name, target in entry.get("imports", {}).items():
            assert not target.startswith(("poc.", "casha.")), (identity, name, target)
            if identity.startswith(("bee.desktop:", "bee.session:", "bee.terminal:", "bee.settings:", "bee.processes:", "bee.console:")):
                allowed_imports = ("bee.desktop:", "bee.protocol:", "bee.application:")
                if identity.startswith("bee.terminal:"):
                    allowed_imports += ("bee.terminal:",)
                if identity.startswith("bee.session:"):
                    allowed_imports += ("bee.session:",)
                if identity.startswith("bee.processes:"):
                    allowed_imports += ("bee.processes:",)
                if identity.startswith("bee.settings:"):
                    allowed_imports += ("bee.settings:",)
                if identity.startswith("bee.console:"):
                    allowed_imports += ("bee.console:",)
                assert target.startswith(allowed_imports), (identity, target)
        source = entry.get("source", "")
        if source.startswith("file://"):
            source_path = (path.parent / source.removeprefix("file://")).resolve()
            assert source_path.is_relative_to(ROOT / "src"), (identity, source_path)
            text = source_path.read_text()
            assert not re.search(r"(?:::|:)\s*any\b", text), identity
            assert "/home/" not in text and "legacy/" not in text, identity
            if identity == "bee.desktop:model":
                assert "require(" not in text and "tty." not in text, identity
        if entry.get("meta", {}).get("type") == "bee.application":
            assert path.is_relative_to(ROOT / "src/apps") or identity == "bee.harness.window:app", ("App outside default package", identity)
        assert entry.get("meta", {}).get("type") != "test", identity

assert not {"bee.workspace:main", "bee.workspace:launch"} & entries.keys(), "Historical combined desktop must not ship"

for entry in entries.values():
    for target in entry.get("imports", {}).values():
        assert target in entries, target
applications = {i for i, e in entries.items() if e.get("meta", {}).get("type") == "bee.application"}
bindings = entries["bee:application_admission"]["bindings"]
assert {b["definition_id"] for b in bindings} == applications
assert len(bindings) == len(applications)
assert entries["bee:base_app_policy"]["policy"] == {"actions": ["process.send"], "resources": "*", "effect": "allow"}
boundary = entries["bee:app_boundary_policy"]["policy"]
assert boundary["effect"] == "deny" and boundary["resources"] == "*"
assert {"process.security", "process.context", "security.policy.get", "security.scope.create", "registry.apply", "registry.apply_version", "registry.overlay.apply"} <= set(boundary["actions"])
for identity in applications:
    entry = entries[identity]
    assert entry["kind"] == "process.lua"
    assert not entry.get("lifecycle", {}).get("auto_start", False)
    assert not entry.get("meta", {}).get("command")
    assert not entry.get("security"), "Authority comes from protected admission"
    metadata = entry["meta"]["application"]
    assert metadata["api_version"] == 1 and metadata["revision"]
    assert metadata["instance_policy"] in {"singleton", "multiple"}
# The desktop adapter consumes explicit core/application value interfaces. This is an
# integration boundary, not permission for reusable Hive code to import core.
# Walk the complete decoder closure so an indirect process/store/runtime-module
# dependency cannot enter through any interface later.
desktop_interfaces = {
    "bee.hive.desktop:protocol": {"bee.protocol:application", "bee.application:arguments"},
    "bee.hive.desktop:catalog": {"bee.protocol:application"},
    "bee.hive.desktop:owner": {"bee.launch:retained_protocol"},
}
checked_interfaces = set()
def check_value_interface(identity):
    if identity in checked_interfaces:
        return
    checked_interfaces.add(identity)
    entry = entries[identity]
    assert entry["kind"] == "library.lua", ("Interface is not a value library", identity)
    assert not entry.get("modules") and not entry.get("security"), ("Interface gained runtime authority", identity)
    for dependency in entry.get("imports", {}).values():
        check_value_interface(dependency)
for interfaces in desktop_interfaces.values():
    for identity in interfaces:
        check_value_interface(identity)

# The application envelope shares the thread owner's opaque-ID decoder only.
# Its complete closure must remain free of runtime and storage authority.
core_value_interfaces = {"bee.protocol:application": {"bee.threads.records:bounds"}}
for interfaces in core_value_interfaces.values():
    for identity in interfaces:
        check_value_interface(identity)

# Launch admission constructs typed grants without importing a placement owner.
check_value_interface("bee.placement:types")

# Generic configuration and binding selection must stay independent of provider
# implementations, including indirect imports through another shared helper.
def check_driver_contract_closure(identity, seen=None):
    seen = set() if seen is None else seen
    if identity in seen:
        return
    seen.add(identity)
    namespace = identity.split(":", 1)[0]
    assert namespace in {"bee.driver", "bee.threads.records"}, ("Provider dependency in generic driver contract", identity)
    for dependency in entries[identity].get("imports", {}).values():
        check_driver_contract_closure(dependency, seen)

for identity in ("bee.driver:resolver", "bee.driver:configuration"):
    check_driver_contract_closure(identity)

# Registry edges, including broker/workspace, must respect the layer boundary.
# Carrier and placement share only the host-selected configuration renderer;
# gateway admission and token materialization remain contract operations.
gateway_configuration_consumers = {"bee.harness.carrier:machine", "bee.placement.native:service", "bee.placement.native:materialization"}
for identity, entry in entries.items():
    location = locations[identity]
    for target in entry.get("imports", {}).values():
        target_location = locations[target]
        if location.parts[0] == "core":
            assert target_location.parts[0] in {"core", "ui"} or target in core_value_interfaces.get(identity, set()), (identity, target)
        if location.parts[0] == "ui":
            assert target_location.parts[0] == "ui", (identity, target)
        if location.parts[0] == "apps":
            assert target_location.parts[0] == "ui" or target_location.parts[:2] == location.parts[:2] or target in {"bee.threads:client", "bee.threads:protocol", "bee.hive:client", "bee.hive:types", "bee.hive:bounds", "bee.threads.records:record", "bee.threads.records:types", "bee.threads.delivery:session", "bee.threads.records:bounds", "bee.sync:protocol"}, (identity, target)
        if location.parts[0] == "threads":
            assert target_location.parts[0] == "threads" or target.startswith("bee.persist:"), (identity, target)
        if location.parts[0] == "placement":
            assert target_location.parts[0] in {"placement", "persist"} or target in {"bee.driver:types", "bee.driver:resolver", "bee.driver:configuration", "bee.driver.kit:quote", "bee.threads.records:bounds", "bee.threads.records:canonical"} or (identity in gateway_configuration_consumers and target == "bee.gateway:configuration"), (identity, target)
        if location.parts[0] == "credentials":
            assert target_location.parts[0] in {"credentials", "persist"} or target.startswith("bee.threads.records:"), (identity, target)
        if location.parts[0] == "approvals":
            assert target_location.parts[0] in {"approvals", "persist"} or target.startswith("bee.threads.records:"), (identity, target)
        if location.parts[0] == "resources":
            assert target_location.parts[0] in {"resources", "persist"} or target.startswith("bee.threads.records:"), (identity, target)
        if location.parts[0] == "persist":
            assert target_location.parts[0] == "persist", (identity, target)
        if location.parts[0] == "driver":
            assert target_location.parts[0] == "driver" or target.startswith("bee.threads.records:"), (identity, target)
        if location.parts[0] == "harness" and location.parts[1:2] != ("carrier",):
            managed_window_targets = {"bee.application:client", "bee.placement.native:window"}
            assert target_location.parts[0] in {"harness", "driver"} or target.startswith("bee.threads.records:") or (identity == "bee.harness.launch:admission" and target == "bee.placement:types") or (identity == "bee.harness.window:app" and target in managed_window_targets), (identity, target)
        if location.parts[0] == "harness" and location.parts[1:2] == ("carrier",):
            assert target_location.parts[0] in {"harness", "driver", "placement"} or target.startswith("bee.threads.records:") or (identity in gateway_configuration_consumers and target == "bee.gateway:configuration"), (identity, target)
        if location.parts[0] == "hive":
            assert target_location.parts[0] == "hive" or target == "bee.threads.records:canonical" or target in desktop_interfaces.get(identity, set()), (identity, target)
visiting, visited = set(), set()
def visit(identity):
    assert identity not in visiting, ("Import cycle", identity)
    if identity in visited:
        return
    visiting.add(identity)
    for target in entries[identity].get("imports", {}).values():
        visit(target)
    visiting.remove(identity)
    visited.add(identity)
for identity in entries:
    visit(identity)
for path in (ROOT / "src/core").rglob("*.lua"):
    assert not any(identity in path.read_text() for identity in applications), path
assert set(entries["bee:presenter_policy"]["policy"]["actions"]) == {
    "tty.observe", "tty.input", "tty.resize", "process.send", "process.monitor"}
assert entries["bee:processes_policy"]["policy"] == {
    "actions": ["system.read"], "resources": ["hosts", "memory", "goroutines", "supervisor"], "effect": "allow"}
assert not entries["bee.processes:app"].get("lifecycle", {}).get("auto_start", False)
assert "security" not in entries["bee.terminal:main"]["modules"]
assert "command" not in entries["bee.terminal:main"].get("meta", {})
assert entries["bee.terminal:render"]["modules"] == ["tty"]
for pure in ["bee.desktop:layout", "bee.terminal:bindings"]:
    assert not entries[pure].get("modules"), pure
# Apps may reduce sync envelopes, never inherit the ledger's storage authority.
def assert_pure_sync(identity, checked=None):
    checked = set() if checked is None else checked
    if identity in checked:
        return
    checked.add(identity)
    entry = entries[identity]
    assert entry["kind"] == "library.lua", identity
    assert not entry.get("modules") and not entry.get("security"), identity
    for dependency in entry.get("imports", {}).values():
        assert_pure_sync(dependency, checked)
assert_pure_sync("bee.sync:protocol")
assert {i for i, e in entries.items() if e["kind"] == "terminal.host"} == {"bee:terminal"}
assert {i for i,e in entries.items() if e["kind"] == "db.sql.sqlite"} == {"bee:workspace_db", "bee:client_db", "bee.threads:db", "bee.placement.native:db", "bee.resources:db", "bee.credentials:db", "bee.approvals:db", "bee.gateway:db", "bee.node:db"}
assert "bee.placement.native:db" in entries["bee:ordinary_app_subsystem_boundary"]["policy"]["resources"]
assert "bee.resources:db" in entries["bee:ordinary_app_subsystem_boundary"]["policy"]["resources"]
assert "bee.credentials:db" in entries["bee:ordinary_app_subsystem_boundary"]["policy"]["resources"]
# The approval owner's methods open their store on an application's behalf (the inbox
# application calls inbox, read, decide and withdraw under its own actor), so the
# approvals store is not on the application deny list; the owner's methods carry the
# store policy and the application binding carries no store access of its own.
assert "bee.approvals:db" not in entries["bee:workspace_storage_boundary"]["policy"]["resources"]
# Ordinary applications keep the subsystem-store deny. The private managed
# window actor is the reviewed execution component that owns its single child.
for binding in entries["bee:application_admission"]["bindings"]:
    if binding["definition_id"] != "bee.harness.window:app":
        assert "bee:ordinary_app_subsystem_boundary" in binding["policies"], binding["definition_id"]
managed_binding = next(b for b in entries["bee:application_admission"]["bindings"] if b["definition_id"] == "bee.harness.window:app")
assert set(managed_binding["policies"]) == {
    "bee:carrier_policy", "bee:placement_store_policy", "bee:placement_exec_policy", "bee:placement_runner_policy",
    "bee:resource_resolve_policy", "bee:credential_materialize_policy", "bee:gateway_materialize_policy", "bee:gateway_supervision_policy",
}
assert set(entries["bee:workspace_storage_boundary"]["policy"]["resources"]) == {"bee:workspace_db", "bee:client_db", "bee.client.db:*", "bee.workspace.db:*"}
inbox_binding = next(b for b in entries["bee:application_admission"]["bindings"] if b["definition_id"] == "bee.inbox:app")
assert set(inbox_binding["policies"]) == {"bee:ordinary_app_subsystem_boundary", "bee:approval_decide_policy", "bee.inbox:client_policy"}
assert set(entries["bee.inbox:client_policy"]["policy"]["actions"]) == {"funcs.call", "registry.get"}
assert "bee.approvals:list" not in entries["bee.inbox:client_policy"]["policy"]["resources"]
manager_binding = next(b for b in entries["bee:application_admission"]["bindings"] if b["definition_id"] == "bee.hive_manager:app")
assert set(manager_binding["policies"]) == {"bee:ordinary_app_subsystem_boundary", "bee.hive_manager:client_policy"}
assert manager_binding.get("catalog_read") is True
assert all(not binding.get("catalog_read", False) for binding in entries["bee:application_admission"]["bindings"] if binding is not manager_binding)
assert set(entries["bee.hive_manager:client_policy"]["policy"]["actions"]) == {"registry.get", "system.read"}
assert entries["bee.hive_manager:source"]["data"] == {"kind": "live"}, "Production ships the live directory; a fixture is an explicit host selection"
timeline_binding = next(b for b in entries["bee:application_admission"]["bindings"] if b["definition_id"] == "bee.timeline:app")
assert set(timeline_binding["policies"]) == {"bee:ordinary_app_subsystem_boundary", "bee.timeline:client_policy"}
timeline_resources = set(entries["bee.timeline:client_policy"]["policy"]["resources"])
assert not timeline_resources & {"bee.threads.delivery:claim", "bee.threads.delivery:ack", "bee.threads.delivery:dispatch", "bee.threads.service:record", "bee.threads.delivery:unsubscribe"}, "Viewing acknowledges no delivery and writes nothing"
for identity, entry in entries.items():
    if identity.startswith("bee.hive_manager:"):
        for target in entry.get("imports", {}).values():
            assert target.startswith(("bee.hive_manager:", "bee.application:", "bee.desktop:", "bee.hive:")), (identity, target)
for method in ("inbox", "read", "decide", "withdraw"):
    assert "bee:approval_store_policy" in entries[f"bee.approvals:{method}"]["security"]["policies"]
assert entries["bee:client_storage_policy"]["policy"] == {"actions": ["db.get"], "resources": ["bee:client_db"], "effect": "allow"}
assert entries["bee:client_db"]["file"] == "${env:bee:workspace_db_path}.client"
for identity, command in [("bee.client:desktop", "bee"), ("bee.client:application", "bee-app")]:
    launch = entries[identity]["meta"]["command"]
    assert launch["name"] == command
    assert set(launch["security"]["policies"]) == {
        "bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy", "bee:local_launcher_spawn_policy"}
    assert identity in entries["bee:core_spawn_boundary"]["policy"]["resources"]
assert entries["bee:local_launcher_spawn_policy"]["policy"]["resources"] == ["bee.launch:supervisor"]
assert "bee:client_db" in entries["bee:workspace_storage_boundary"]["policy"]["resources"]
assert not any(e["kind"] == "http.service" for e in entries.values())
print(f"Architecture: {len(entries)} entries; on-demand default applications, closed imports, denied ambient app authority")

# Inspect what Wippy actually loads, including transitive dependency entries.
import json
import os
import shutil
import subprocess
import tempfile

runtime = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()
allowed = {"bee", "bee.applications", "bee.desktop", "bee.protocol", "bee.host", "bee.interaction", "bee.launch",
           "bee.node", "bee.sync",
           "bee.session", "bee.settings", "bee.processes", "bee.inbox", "bee.terminal", "bee.workspace", "bee.console", "bee.application", "bee.storage", "bee.threads", "bee.threads.persist", "bee.threads.records", "bee.threads.service", "bee.hive", "bee.hive.telemetry", "bee.hive.supervisor", "bee.hive.desktop", "bee.hive_manager", "bee.timeline", "bee.client", "bee.threads.delivery", "bee.threads.projection", "bee.threads.carrier", "bee.threads.approvals", "bee.driver", "bee.driver.kit", "bee.driver.transport", "bee.driver.claude", "bee.driver.codex", "bee.harness", "bee.harness.catalog", "bee.harness.carrier", "bee.harness.launch", "bee.harness.permission", "bee.harness.window", "bee.persist", "bee.placement", "bee.placement.native", "bee.resources", "bee.credentials", "bee.approvals", "bee.gateway"}

def check_loaded(cwd, packed=False):
    loaded = json.loads(subprocess.check_output([str(runtime), "registry", "list", "--json"], cwd=cwd))
    assert {e["id"] for e in loaded} == set(entries), "Loaded entries differ from the declared core"
    for entry in loaded:
        namespace = entry["id"].split(":", 1)[0]
        assert namespace in allowed, f'Unexpected loaded namespace: {entry["id"]}'
        assert entry.get("meta", {}).get("type") != "test", entry["id"]
    print(f"{'Pack' if packed else 'Source'} registry: {len(loaded)} entries; no legacy namespaces")

check_loaded(ROOT)
with tempfile.TemporaryDirectory(prefix="bee-pack-audit-") as directory:
    folder = Path(directory)
    shutil.copy2(ROOT / "dist/bee.wapp", folder / "bee.wapp")
    (folder / "wippy.lock").write_text("directories:\n  modules: ./vendor\n  src: ./bee.wapp\nmodules: []\n")
    check_loaded(folder, packed=True)

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
            assert path.is_relative_to(ROOT / "src/apps"), ("App outside default package", identity)
        assert entry.get("meta", {}).get("type") != "test", identity

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
# Registry edges, including broker/workspace, must respect the layer boundary.
for identity, entry in entries.items():
    location = locations[identity]
    for target in entry.get("imports", {}).values():
        target_location = locations[target]
        if location.parts[0] == "core":
            assert target_location.parts[0] in {"core", "ui"}, (identity, target)
        if location.parts[0] == "ui":
            assert target_location.parts[0] == "ui", (identity, target)
        if location.parts[0] == "apps":
            assert target_location.parts[0] == "ui" or target_location.parts[:2] == location.parts[:2] or target in {"bee.threads:client", "bee.threads:protocol"}, (identity, target)
        if location.parts[0] == "threads":
            assert target_location.parts[0] == "threads", (identity, target)
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
assert {i for i, e in entries.items() if e["kind"] == "terminal.host"} == {"bee:terminal"}
assert {i for i,e in entries.items() if e["kind"] == "db.sql.sqlite"} == {"bee:workspace_db", "bee.threads:db"}
assert entries["bee:client_storage_policy"]["policy"] == {"actions": ["db.get"], "resources": ["bee:client_db"], "effect": "allow"}
assert "bee:client_db" not in entries, "Client data resource belongs to the future client launcher"
assert "bee:client_db" in entries["bee:workspace_storage_boundary"]["policy"]["resources"]
assert not any(e["kind"] == "http.service" for e in entries.values())
print(f"Architecture: {len(entries)} entries; on-demand default applications, closed imports, denied ambient app authority")

# Inspect what Wippy actually loads, including transitive dependency entries.
import json
import os
import shutil
import subprocess
import tempfile

runtime = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()
allowed = {"bee", "bee.applications", "bee.desktop", "bee.protocol", "bee.host", "bee.interaction",
           "bee.session", "bee.settings", "bee.processes", "bee.terminal", "bee.workspace", "bee.console", "bee.application", "bee.storage", "bee.threads", "bee.threads.persist", "bee.test_status", "bee.client"}

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

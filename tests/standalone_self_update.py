"""Prove source-free self-update, exact approval, live About, and offline restore."""
from pathlib import Path
import json
import hashlib
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

import yaml
from workspace import ROOT, RUNTIME, database_environment
from native_self_update import exercise as native_exercise

PROBE = r'''
local registry = require("registry")
local process = require("process")
local funcs = require("funcs")
local logger = require("logger")
local bounds = require("bounds")
local inventory = require("inventory")
local view = require("view")
local appearance = require("appearance")
local live_updates = require("live_updates")
local catalog = require("catalog")
local REQUEST = {action = "update", component = "bee/bee", version = "__TARGET__", parameters = {}, migration_policy = "none"}
local function call(operation: string, request: unknown?, digest: string?): {[string]: unknown}
    local raw, problem = funcs.new():call("bee.hub.binding:call", {operation = operation, request = request, expected_digest = digest})
    if problem then error(tostring(problem)) end
    local reply = bounds.object(raw)
    assert(reply, "invalid Hub reply")
    return reply
end
local function captured(): inventory.Result
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local decoded, problem = inventory.decode(state, snapshot:version():id())
    assert(decoded, tostring(problem))
    return decoded
end
local function about(expected: string, phase: string)
    local status = live_updates.decode(call("updates"))
    assert(status.state == "ready", status.message)
    local drawn = view.draw(160, 100, appearance.defaults(), "about", 0, nil, status, false)
    local text = table.concat(drawn.rows, "\n"):gsub("\27%[[0-9;]*m", "")
    assert(text:find("BEE SETTINGS · ABOUT", 1, true), "missing About heading")
    assert(text:find("bee/bee  installed " .. expected, 1, true), "About does not show installed " .. expected .. "\n" .. text)
    logger:info("STANDALONE_SELF_UPDATE_ABOUT", {phase = phase, version = expected})
end
local function check(expected: string)
    local installed = captured()
    assert(installed.deployment == "bee/bee", "missing standalone deployment")
    local bee, terminal = false, false
    for _, item in ipairs(installed.modules) do
        if item.component == "bee/bee" then assert(item.version == expected, "wrong live Bee selection"); bee = true end
        if item.component == "wippy/terminal" then assert(item.version == "0.4.5", "wildcard upgraded installed terminal"); terminal = true end
    end
    assert(bee and terminal, "missing Bee/terminal inventory")
end
local function live(): integer
    local pid = process.pid()
    local running_code = catalog.code(assert(registry.snapshot()), "bee.settings.app:app")
    check("__BASELINE__")
    about("__BASELINE__", "baseline")
    for _, root in ipairs(captured().roots) do assert(root.component ~= "bee/bee", "invented standalone registry root") end
    local prepared = call("plan", REQUEST)
    assert(prepared.ok == true, tostring(prepared.message))
    local plan = bounds.object(prepared.value)
    assert(plan and plan.ready == true and plan.root_operation == "create", "first standalone plan is not ready/create")
    local root_id = bounds.id(plan.root_id)
    assert(root_id and not assert(registry.snapshot()):get(root_id), "first selection destination is already resident")
    local digest = bounds.line(plan.digest, 64)
    assert(digest, "missing approval digest")
    local modules = bounds.array(plan.modules, 64)
    assert(modules, "missing planned modules")
    local retained = false
    for _, raw in ipairs(modules) do
        local item = bounds.object(raw)
        if item and item.component == "wippy/terminal" then
            assert(item.version == "0.4.5" and item.change == "keep", "planner does not predict installed wildcard selection")
            retained = true
        end
    end
    assert(retained, "wildcard dependency is absent from plan")
    logger:info("STANDALONE_SELF_UPDATE_PLAN", {digest = digest, owner = tostring(pid)})
    -- Exact digest confirmation is the same approval used by Modules Confirm.
    local refused = call("apply", REQUEST, string.rep("0", 64))
    assert(refused.ok == false, "wrong approval digest was accepted")
    logger:info("STANDALONE_SELF_UPDATE_APPROVE", {digest = digest})
    local result = call("apply", REQUEST, digest)
    assert(result.ok == true, tostring(result.code) .. ": " .. tostring(result.message))
    local receipt = bounds.object(result.value)
    assert(receipt and receipt.state == "complete", "missing completed receipt")
    assert(process.pid() == pid, "owner process changed during apply")
    local saved = call("status", nil, digest)
    local persisted = bounds.object(saved.value)
    assert(saved.ok == true and persisted and persisted.state == "complete", "completed receipt was not persisted")
    local renderer = assert(registry.snapshot()):get("bee.settings.app:view")
    local renderer_data = renderer and bounds.object(renderer.data)
    local renderer_source = renderer_data and renderer_data.source
    assert(type(renderer_source) == "string" and renderer_source:find("proof marker __TARGET__", 1, true),
        "pack apply kept the old live Settings renderer despite changing its installed version")
    assert(catalog.code(assert(registry.snapshot()), "bee.settings.app:app") ~= running_code,
        "pack apply kept the old live Settings definition despite changing its installed version")
    check("__TARGET__")
    about("__TARGET__", "live")
    logger:info("STANDALONE_SELF_UPDATE_APPLIED", {owner_before = tostring(pid), owner_after = tostring(process.pid())})
    return 0
end
local function offline(): integer
    check("__TARGET__")
    about("__TARGET__", "offline")
    logger:info("STANDALONE_SELF_UPDATE_OFFLINE_PASS")
    return 0
end
local function main(): integer
    local ok, result = pcall(live)
    if not ok then logger:error("STANDALONE_SELF_UPDATE_FAILURE", {cause = tostring(result)}); return 1 end
    return 0
end
return {main = main, offline = offline}
'''


BASELINE = "0.1.0-selfupdate.fixture.1"
TARGET = "0.1.0-selfupdate.fixture.2"


def build_deployments(folder, seed):
    # Reuse sealed artifact resources and registrations while packing current
    # production Lua into both versions. No runtime pin or publication changes.
    lock, paths = artifact_paths(seed)
    sources, declarations = {}, {}
    for root in (ROOT / "src", ROOT / "modules"):
        for index in root.rglob("_index.yaml"):
            document = yaml.safe_load(index.read_text())
            for entry in document.get("entries", []):
                source = entry.get("source", "")
                if entry.get("kind") in {"library.lua", "function.lua", "process.lua"} and source.startswith("file://"):
                    identity = f"{document['namespace']}:{entry['name']}"
                    sources[identity] = str(index.parent / source.removeprefix("file://"))
                    declarations[identity] = {"Component": "bee/bee" if root.name == "src" else "bee/" + index.relative_to(root).parts[0],
                                              "Kind": entry["kind"], "Meta": entry.get("meta", {}),
                                              "Data": {key: value for key, value in entry.items() if key not in {"name", "kind", "meta", "source"}}}
    packs, deployments = [], []
    for name, version in (("baseline", BASELINE), ("target", TARGET)):
        deployment = folder / name
        deployment.mkdir()
        copied = json.loads(json.dumps(lock))
        for row in copied["modules"]:
            key = f"{row['name']}@{row['version']}"
            path = Path(paths[key])
            org, module = row["name"].split("/")
            if org == "bee":
                row["version"] = version
                destination = deployment / ".wippy/vendor" / org / f"{module}-{version}.wapp"
                packs.append({"Input": str(path), "Output": str(destination), "Version": version, "Component": row["name"]})
            else:
                destination = deployment / ".wippy/vendor" / org / path.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
        copied["directories"] = {"modules": ".wippy", "src": "src"}
        (deployment / "wippy.lock").write_text(yaml.safe_dump(copied, sort_keys=False))
        deployments.append(deployment)
    config = folder / "pack-config.json"
    manifest = json.loads(RUNTIME.with_name(RUNTIME.name + ".provenance.json").read_text())["manifest"]
    native = manifest["native"]
    identity = {"runtime": manifest["runtime"]["repository"], "runtime_commit": manifest["runtime"]["commit"],
                "native": native[0]["module"], "native_version": native[0]["version"],
                "native_components": [{"package": item["package"], "version": item["version"]} for item in native]}
    config.write_text(json.dumps({"Packs": packs, "Sources": sources, "Declarations": declarations, "Identity": identity}))
    result = subprocess.run(["go", "-C", str(ROOT / "native"), "run", "-mod=readonly",
                             str(ROOT / "tests/standalone_self_update_packs.go"), str(config)],
                            check=True, capture_output=True, text=True, timeout=120,
                            env=dict(os.environ, GOWORK="off", GOTOOLCHAIN="go1.27.0"))
    digests = dict(line.rsplit(" ", 1) for line in result.stdout.splitlines())
    for deployment in deployments:
        copied, artifacts = artifact_paths(deployment)
        for row in copied["modules"]:
            if row["name"].startswith("bee/"):
                row["hash"] = "sha256:" + digests[artifacts[f"{row['name']}@{row['version']}"]]
        (deployment / "wippy.lock").write_text(yaml.safe_dump(copied, sort_keys=False))
    return deployments


def artifact_paths(deployment):
    lock = yaml.safe_load((deployment / "wippy.lock").read_text())
    assert [row["name"] for row in lock["modules"] if row.get("root")] == ["bee/bee"]
    assert not lock.get("replacements"), "requires a sealed standalone deployment"
    modules = Path(lock["directories"]["modules"])
    vendor = modules if modules.name == "vendor" else modules / "vendor"
    result = {}
    for row in lock["modules"]:
        org, name = row["name"].split("/")
        result[f"{row['name']}@{row['version']}"] = str(deployment / vendor / org / f"{name}-{row['version']}.wapp")
    return lock, result


def build_native(folder, baseline):
    """Embed the exact baseline packs in the real public native launcher."""
    supplied = os.environ.get("BEE_SELF_UPDATE_BINARY")
    if supplied:
        binary = Path(supplied).resolve()
        provenance = json.loads(binary.with_name(binary.name + ".provenance.json").read_text())
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == provenance["artifacts"]["binary"], "native binary digest changed"
        lock, _ = artifact_paths(baseline)
        expected = {(row["name"], row["version"], row["hash"].removeprefix("sha256:")) for row in lock["modules"]}
        actual = {(pack["module"], pack["version"], pack["sha256"]) for pack in provenance["manifest"]["application"]["packs"]}
        assert actual == expected, "native binary does not embed the exact baseline packs"
        return binary
    manifest = json.loads(RUNTIME.with_name(RUNTIME.name + ".provenance.json").read_text())["manifest"]
    lock, paths = artifact_paths(baseline)
    manifest["application"]["packs"] = [
        {"module": row["name"], "version": row["version"],
         "path": os.path.relpath(paths[f"{row['name']}@{row['version']}"], folder),
         "sha256": row["hash"].removeprefix("sha256:")}
        for row in lock["modules"]]
    bundle = folder / "native.build.json"
    bundle.write_text(json.dumps(manifest))
    binary = folder / "bee"
    subprocess.run(["make", "standalone-sealed", f"BEE_BUNDLE_MANIFEST={bundle}",
                    f"BEE_BINARY={binary}"], cwd=ROOT, check=True, timeout=600)
    return binary


def native_attached(folder, baseline, target, url):
    """Apply through Modules on a PTY, then navigate About and detach."""
    binary = build_native(folder, baseline)
    scratch = folder / "native"
    for name in ("project", "tmp", "home/.config"):
        (scratch / name).mkdir(parents=True, exist_ok=True)
    baseline_lock, _ = artifact_paths(baseline)
    target_lock, _ = artifact_paths(target)
    versions = [next(row["version"] for row in lock["modules"] if row.get("root"))
                for lock in (baseline_lock, target_lock)]
    args = SimpleNamespace(binary=binary, from_version=versions[0], to_version=versions[1],
                           marker=versions[1], code_marker="proof marker " + versions[1],
                           baseline_code_marker="proof marker " + versions[0], evidence=folder, hub_url=url)
    native_exercise(args, scratch, "live")
    return args, scratch


def run_probe(folder, environment, command, marker, offline=False):
    arguments = [str(RUNTIME), "run", "--verbose", command, "--host", "bee:workers"]
    if offline:
        arguments = ["unshare", "--user", "--map-root-user", "--net", "--", *arguments]
    log = folder / f"{command}.log"
    with log.open("w") as output:
        owner = subprocess.Popen(arguments, cwd=folder, env=environment, stdout=output, stderr=subprocess.STDOUT)
        pid = owner.pid
        deadline = time.monotonic() + 120
        try:
            while owner.poll() is None and time.monotonic() < deadline:
                evidence = log.read_text()
                if marker in evidence:
                    assert owner.pid == pid, "runtime owner PID changed"
                time.sleep(0.1)
            if owner.poll() is None:
                raise AssertionError(f"{command} exceeded 120s; log: {log}")
            evidence = log.read_text()
            errors = "\n".join(line for line in evidence.splitlines()
                               if "STANDALONE_SELF_UPDATE" in line or "\tERROR\t" in line)
            assert owner.returncode == 0 and marker in evidence, f"{errors}\nOwner log: {log}"
        finally:
            if owner.poll() is None:
                owner.terminate()
                try:
                    owner.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    owner.kill()
                    owner.wait(timeout=10)
    print(f"{command}: runtime owner PID {pid}, exit {owner.returncode}", flush=True)
    print("\n".join(line for line in evidence.splitlines() if "STANDALONE_SELF_UPDATE" in line), flush=True)
    return pid


def exercise(folder, baseline, target):
    lock, paths = artifact_paths(baseline)
    target_lock, target_paths = artifact_paths(target)
    paths.update(target_paths)
    # Advertise a newer wildcard candidate while retaining the actual installed
    # terminal artifact. The solver must not download this unselected candidate.
    assert "wippy/terminal@0.4.5" in paths
    paths["wippy/terminal@0.4.6"] = paths["wippy/terminal@0.4.5"]
    descriptions = folder / "entries.json"
    descriptions.write_text("{}")
    pack_paths = folder / "artifacts.json"
    pack_paths.write_text(json.dumps(paths))
    binary = folder / "hub-fixture"
    subprocess.run(["go", "-C", str(ROOT / "native"), "build", "-mod=readonly", "-o", str(binary),
                    str(ROOT / "tests/hub_migration_fixture.go")], check=True, timeout=120,
                   env=dict(os.environ, GOWORK="off", GOTOOLCHAIN="go1.27.0"))
    with (folder / "hub.log").open("w") as log:
        server = subprocess.Popen([str(binary), str(descriptions), str(pack_paths)], stdout=subprocess.PIPE,
                                  stderr=log, text=True)
        try:
            selector = selectors.DefaultSelector()
            selector.register(server.stdout, selectors.EVENT_READ)
            assert selector.select(timeout=10), "fixture Hub did not start"
            url = server.stdout.readline().strip()
            selector.close()
            assert url.startswith("http://127.0.0.1:"), url
            project = folder / "owner"
            project.mkdir()
            shutil.copy2(baseline / "wippy.lock", project / "wippy.lock")
            for path in artifact_paths(baseline)[1].values():
                relative = Path(path).relative_to(baseline)
                (project / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, project / relative)
            probe = project / lock["directories"].get("src", "src") / "probe"
            probe.mkdir(parents=True)
            baseline_version = next(row["version"] for row in lock["modules"] if row.get("root"))
            target_version = next(row["version"] for row in target_lock["modules"] if row.get("root"))
            (probe / "main.lua").write_text(PROBE.replace("__BASELINE__", baseline_version).replace("__TARGET__", target_version))
            imports = {"bounds": "bee.threads.records:bounds", "inventory": "bee.hub:inventory",
                       "view": "bee.settings.app:view", "appearance": "bee.app:appearance",
                       "live_updates": "bee.settings.app:live_updates", "catalog": "bee.apps:catalog"}
            entries = [
                {"name": "read", "kind": "security.policy", "policy": {
                    "actions": ["registry.get", "registry.resolution.get", "bee.hub.read"], "resources": "*", "effect": "allow"}},
                {"name": "call", "kind": "security.policy", "policy": {
                    "actions": ["funcs.call"], "resources": ["bee.hub.binding:call"], "effect": "allow"}},
                {"name": "manage", "kind": "security.policy", "policy": {
                    "actions": ["bee.hub.manage", "bee.hub.self_update"], "resources": ["bee/bee"], "effect": "allow"}},
            ]
            for name, method in (("standalone-self-update", "main"), ("standalone-self-update-offline", "offline")):
                entries.append({"name": method, "kind": "process.lua", "source": "file://main.lua", "method": method,
                                "modules": ["registry", "process", "funcs", "logger"], "imports": imports,
                                "security": {"policies": [f"selfroot.probe:{policy}" for policy in ("read", "call", "manage")]},
                                "meta": {"command": {"name": name, "security": {"actor": {"id": "selfroot.probe"}}}}})
            (probe / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "selfroot.probe", "entries": entries}, sort_keys=False))
            (project / ".wippy.yaml").write_text(yaml.safe_dump({"version": "1.0", "registry": {
                "enable_history": True, "history_type": "sqlite", "history_path": str(project / "registry.db")}}))
            home = project / "home"
            home.mkdir()
            environment = database_environment(project, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                                               WIPPY_REGISTRY=url, TMPDIR=str(folder / "tmp"))
            lint = subprocess.run([str(RUNTIME), "lint", "--ns", "selfroot.probe", "--strict-any",
                                   "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
                                  cwd=project, env=environment, text=True, capture_output=True, timeout=120)
            assert lint.returncode == 0, lint.stdout + lint.stderr
            run_probe(project, environment, "standalone-self-update", "STANDALONE_SELF_UPDATE_APPLIED")
            native_args, native_scratch = native_attached(folder, baseline, target, url)
            server.terminate()
            server.wait(timeout=10)
            # The same registry/history and cached artifacts boot with no Hub
            # and no network interface in a fresh runtime owner.
            run_probe(project, environment, "standalone-self-update-offline", "STANDALONE_SELF_UPDATE_OFFLINE_PASS", offline=True)
            subprocess.run(["unshare", "--user", "--map-root-user", "--net", "--", sys.executable,
                            str(Path(__file__).resolve()), "--native-offline", str(native_args.binary),
                            str(native_scratch), str(folder), native_args.from_version, native_args.to_version],
                           check=True, timeout=300)
        finally:
            if server.poll() is None:
                server.terminate()
                server.wait(timeout=10)
            server.stdout.close()
    print("Standalone self-update PASS: baseline -> plan -> approve -> APPLIED, same PID, live About, offline restart.", flush=True)


def main(deployment=None):
    parent = ROOT / ".wippy/selfupdate-standalone"
    parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="proof-", dir=parent))
    try:
        (folder / "tmp").mkdir()
        os.environ["TMPDIR"] = str(folder / "tmp")
        if os.environ.get("BEE_SELF_UPDATE_TARGET_DEPLOYMENT"):
            baseline = Path(deployment).resolve()
            target = Path(os.environ["BEE_SELF_UPDATE_TARGET_DEPLOYMENT"]).resolve()
        else:
            seed = Path(deployment).resolve() if deployment and Path(deployment).is_dir() else RUNTIME.parents[2] / "dist/portable-deployment"
            assert seed.is_dir(), "build a sealed deployment with make native-pack and pass BEE_DEPLOYMENT"
            baseline, target = build_deployments(folder, seed)
        exercise(folder, baseline, target)
    except Exception:
        print(f"Standalone fixture retained: {folder}", flush=True)
        raise
    else:
        if os.environ.get("BEE_SELF_UPDATE_EVIDENCE"):
            evidence = Path(os.environ["BEE_SELF_UPDATE_EVIDENCE"]).resolve()
            evidence.mkdir(parents=True, exist_ok=True)
            for artifact in (*folder.glob("*.frame.txt"), *folder.glob("*.pids.json")):
                shutil.copy2(artifact, evidence / artifact.name)
        shutil.rmtree(folder)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--native-offline":
        args = SimpleNamespace(binary=Path(sys.argv[2]), evidence=Path(sys.argv[4]),
                               from_version=sys.argv[5], to_version=sys.argv[6], marker=sys.argv[6],
                               code_marker="proof marker " + sys.argv[6])
        native_exercise(args, Path(sys.argv[3]), "offline")
    else:
        main(sys.argv[1] if len(sys.argv) > 1 else None)

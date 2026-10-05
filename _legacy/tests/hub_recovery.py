"""Prove restart reconciliation for a Hub publication interrupted before verify."""

from pathlib import Path
import os
import selectors
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()
COMPONENT = "wippy/test"
VERSION = "0.4.16"


PROBE = r'''-- MIT. Crash/restart acceptance for a published Hub receipt.
local funcs = require("funcs")
local registry = require("registry")
local logger = require("logger")
local bounds = require("bounds")

local COMPONENT = "wippy/test"
local VERSION = "0.4.16"
local RECEIPT_PREFIX = "bee.hub.operations:"
local REQUEST = {action = "install", component = COMPONENT, version = VERSION}

local function call(operation, request, digest)
    local value, problem = funcs.new():call("bee.hub.binding:call",
        {operation = operation, request = request, expected_digest = digest})
    assert(not problem, tostring(problem))
    local reply = bounds.object(value)
    assert(reply, "invalid Hub facade result")
    return reply
end

local function receipt()
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local found = nil
    for _, entry in ipairs(state.entries) do
        if type(entry.id) == "string" and entry.id:sub(1, #RECEIPT_PREFIX) == RECEIPT_PREFIX then
            assert(not found, "more than one operation receipt was published")
            found = bounds.object(entry.data)
        end
    end
    assert(found, "published operation receipt is missing")
    return found
end

local function root_version()
    local snapshot = assert(registry.snapshot())
    local state = assert(snapshot:state())
    local count, version = 0, nil
    for _, entry in ipairs(state.entries) do
        local data = bounds.object(entry.data)
        local ownership = bounds.object(entry.registry)
        if entry.kind == "ns.dependency" and data and data.component == COMPONENT
            and ownership and ownership.root == true then
            count = count + 1
            version = data.version
        end
    end
    assert(count == 1, "expected exactly one Hub dependency root, got " .. tostring(count))
    return version
end

local function main()
    local planned = call("plan", REQUEST)
    assert(planned.ok == true, "plan failed: " .. tostring(planned.message))
    local measured = bounds.object(planned.value)
    assert(measured and type(measured.digest) == "string" and #measured.digest == 64,
        "plan did not return a digest")

    -- The harness kills the runtime while the publisher is blocked just after
    -- the registry commit. It therefore never receives this call's reply.
    call("apply", REQUEST, measured.digest)
end

local function restart()
    local published = receipt()
    assert(published.state == "published", "restart did not find the interrupted receipt")
    local digest = bounds.line(published.digest, 64)
    assert(digest, "published receipt has no usable plan digest")

    local result = call("apply", REQUEST, digest)
    local completed = bounds.object(result.value)
    if not (result.ok == true and result.replayed == true and completed and completed.state == "complete") then
        logger:error("HUB_RECOVERY_REPLAY_RESULT ok=" .. tostring(result.ok) .. " replayed=" .. tostring(result.replayed)
            .. " code=" .. tostring(result.code) .. " state=" .. tostring(completed and completed.state)
            .. " message=" .. tostring(completed and completed.message))
    end
    assert(result.ok == true and result.replayed == true, "replay did not reconcile the publication")
    assert(completed and completed.state == "complete", "replay did not complete the receipt")
    assert(root_version() == VERSION, "replay changed the dependency root")

    local changed = call("apply", {action = "install", component = COMPONENT, version = "0.4.17"}, digest)
    assert(changed.ok == false and changed.code == "STALE",
        "changed request reused the published receipt: " .. tostring(changed.code))
    assert(root_version() == VERSION, "changed request overwrote the dependency root")

    local installed = call("installed")
    assert(installed.ok == true, "inventory read failed after reconciliation")
    local inventory = bounds.object(installed.value)
    assert(inventory and type(inventory.modules) == "table", "invalid installed inventory")
    local selected = nil
    for _, module in ipairs(inventory.modules) do
        if type(module) == "table" and module.component == COMPONENT then selected = module.version end
    end
    assert(selected == VERSION, "reconciled inventory selected " .. tostring(selected))
    logger:info("HUB_RECOVERY_RESTART_PASS")
end

local function tamper()
    local snapshot = assert(registry.snapshot())
    for _, entry in ipairs(assert(snapshot:state()).entries) do
        local data = bounds.object(entry.data)
        if entry.kind == "ns.dependency" and data and data.component == COMPONENT then
            local changes = assert(snapshot:changes())
            assert(changes:update({id = entry.id, kind = "ns.dependency", dependency_root = true,
                data = {component = COMPONENT, version = "0.4.17"}}))
            assert(changes:apply())
            logger:info("HUB_RECOVERY_EDIT_PASS")
            return
        end
    end
    error("no published root to edit")
end

local function conflict()
    local published = receipt()
    assert(published.state == "published", "conflict case lost the interrupted receipt")
    local digest = assert(bounds.line(published.digest, 64))
    local revision = assert(registry.snapshot()):version():id()
    assert(call("status", nil, digest).ok == true, "cannot read interrupted receipt")
    assert(assert(registry.snapshot()):version():id() == revision, "status changed registry state")
    local result = call("apply", REQUEST, digest)
    local completed = bounds.object(result.value)
    assert(result.ok == true and completed and completed.state == "recovery_required",
        "conflicting root was falsely marked complete")
    assert(root_version() == "0.4.17", "reconciliation overwrote the later root edit")
    logger:info("HUB_RECOVERY_CONFLICT_PASS")
end

local function checked(label, run)
    local ok, problem = pcall(run)
    if not ok then
        logger:error(label .. " " .. tostring(problem))
        error(tostring(problem))
    end
end

return {
    main = function() checked("HUB_RECOVERY_MAIN_FAILURE", main) end,
    restart = function() checked("HUB_RECOVERY_RESTART_FAILURE", restart) end,
    tamper = tamper, conflict = conflict,
}
'''


PROBE_INDEX = r'''version: '1.0'
namespace: bee.hubrecoveryprobe
entries:
- name: policy
  kind: security.policy
  policy:
    actions: [funcs.call]
    resources: [bee.hub.binding:call]
    effect: allow
- name: management_policy
  kind: security.policy
  policy:
    actions: [bee.hub.manage]
    resources: [wippy/test]
    effect: allow
- name: reader_policy
  kind: security.policy
  policy:
    actions: [bee.hub.read, registry.get]
    resources: '*'
    effect: allow
- name: main
  kind: process.lua
  source: file://main.lua
  method: main
  modules: [funcs, registry, logger]
  imports:
    bounds: bee.values:bounds
  security:
    policies: [bee.hubrecoveryprobe:policy, bee.hubrecoveryprobe:management_policy, bee.hubrecoveryprobe:reader_policy]
  meta:
    command:
      name: hub-recovery-probe
      security: {actor: {id: bee.hubrecoveryprobe}}
- name: restart
  kind: process.lua
  source: file://main.lua
  method: restart
  modules: [funcs, registry, logger]
  imports:
    bounds: bee.values:bounds
  security:
    policies: [bee.hubrecoveryprobe:policy, bee.hubrecoveryprobe:management_policy, bee.hubrecoveryprobe:reader_policy]
  meta:
    command:
      name: hub-recovery-restart
      security: {actor: {id: bee.hubrecoveryprobe}}
- name: writer_policy
  kind: security.policy
  policy:
    actions: [registry.get, registry.apply, registry.update.ns.dependency]
    resources: '*'
    effect: allow
- name: tamper
  kind: process.lua
  source: file://main.lua
  method: tamper
  modules: [funcs, registry, logger]
  imports:
    bounds: bee.values:bounds
  security:
    policies: [bee.hubrecoveryprobe:writer_policy]
  meta:
    command:
      name: hub-recovery-tamper
      security: {actor: {id: bee.hub_recovery_editor}}
- name: conflict
  kind: process.lua
  source: file://main.lua
  method: conflict
  modules: [funcs, registry, logger]
  imports:
    bounds: bee.values:bounds
  security:
    policies: [bee.hubrecoveryprobe:policy, bee.hubrecoveryprobe:management_policy, bee.hubrecoveryprobe:reader_policy]
  meta:
    command:
      name: hub-recovery-conflict
      security: {actor: {id: bee.hubrecoveryprobe}}
'''


def command_environment(folder):
    return {
        "HOME": str(folder / "home"),
        "XDG_CONFIG_HOME": str(folder / "config"),
        "XDG_DATA_HOME": str(folder / "data"),
        "XDG_STATE_HOME": str(folder / "state"),
        "PATH": "/usr/bin:/bin",
        "GOMAXPROCS": "2",
        "TMPDIR": os.environ.get("TMPDIR", str(folder)),
    }


def prepare_fixture(folder):
    shutil.copytree(ROOT / "tests/fixtures/hub_manage", folder / "src")
    for module in ("values", "hub", "hive", "persist", "sync", "threads", "placement", "driver"):
        shutil.copytree(ROOT / "modules" / module, folder / "modules" / module)
    (folder / "src/hubrecoveryprobe").mkdir()
    (folder / "src/hubrecoveryprobe/main.lua").write_text(PROBE)
    (folder / "src/hubrecoveryprobe/_index.yaml").write_text(PROBE_INDEX)
    (folder / "wippy.lock").write_text(
        "directories:\n  modules: .wippy\n  src: ./src\nmodules:\n"
        "- name: bee/values\n  version: 0.1.0-dev\n"
        "- name: bee/hub\n  version: 0.1.0-dev\n"
        "- name: bee/hive\n  version: 0.1.0-dev\n"
        "- name: bee/persist\n  version: 0.1.0-dev\n"
        "- name: bee/sync\n  version: 0.1.0-dev\n"
        "- name: bee/threads\n  version: 0.1.0-dev\n"
        "- name: bee/placement\n  version: 0.1.0-dev\n- name: bee/driver\n  version: 0.1.0-dev\n"
    )
    (folder / ".wippy.yaml").write_text(
        "version: '1.0'\nregistry:\n  enable_history: true\n"
        "  history_type: sqlite\n  history_path: registry.db\nshutdown:\n  timeout: 2s\n"
        "workspace:\n  replacements:\n"
        "    bee/values: ./modules/values\n"
        "    bee/hub: ./modules/hub\n    bee/hive: ./modules/hive\n    bee/persist: ./modules/persist\n"
        "    bee/sync: ./modules/sync\n    bee/threads: ./modules/threads\n    bee/placement: ./modules/placement\n    bee/driver: ./modules/driver\n"
    )


def run(runtime, folder, command):
    result = subprocess.run(
        [str(runtime), "run", "--verbose", "--host", "bee:hub_workers", "--", command],
        cwd=folder,
        env=command_environment(folder),
        capture_output=True,
        text=True,
        timeout=180,
    )
    output = result.stdout + result.stderr
    (folder / (command + ".log")).write_text(output)
    if result.returncode != 0:
        raise AssertionError(f"{command} failed ({result.returncode})\n{output}")
    marker = {"hub-recovery-restart": "HUB_RECOVERY_RESTART_PASS",
              "hub-recovery-tamper": "HUB_RECOVERY_EDIT_PASS",
              "hub-recovery-conflict": "HUB_RECOVERY_CONFLICT_PASS"}[command]
    assert marker in output, f"{command} omitted success marker\n{output}"
    print(marker)
    return output


def kill_after_publication(runtime, folder):
    """Kill the actual runtime after the source-only post-commit marker."""
    process = subprocess.Popen(
        [str(runtime), "run", "--verbose", "--host", "bee:hub_workers", "--", "hub-recovery-probe"],
        cwd=folder,
        env=command_environment(folder),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = []
    deadline = time.monotonic() + 60
    marker = "HUB_RECOVERY_INJECTED_AFTER_PUBLICATION"
    seen = False
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                break
            for key, _ in selector.select(timeout=0.25):
                line = key.fileobj.readline()
                if not line:
                    continue
                output.append(line)
                if marker in line:
                    seen = True
                    break
            if seen:
                break
        if not seen:
            raise AssertionError("publication crash marker was not observed\n" + "".join(output))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, 9)
        process.wait(timeout=10)
        selector.close()
    if process.returncode != -9:
        raise AssertionError(f"runtime was not SIGKILLed (return code {process.returncode})\n" + "".join(output))


FAILURE_PROBE = r'''-- MIT. Definite resolver rejection survives the facade, receipt, replay and restart.
local funcs = require("funcs")
local logger = require("logger")
local bounds = require("bounds")
local installation = require("installation")
local REQUEST = {action = "install", component = "wippy/test", version = "0.4.16"}
local function call(operation: string, request: unknown?, digest: string?): {[string]: unknown}
    local raw, problem = funcs.new():call("bee.hub.binding:call",
        {operation = operation, request = request, expected_digest = digest})
    if problem then error(tostring(problem)) end
    local reply = bounds.object(raw)
    if not reply then error("invalid Hub reply") end
    return reply
end
local function main(): integer
    local history = call("status")
    local page = bounds.object(history.value)
    local operations = page and bounds.array(page.operations, 25) or nil
    local prior = operations and bounds.object(operations[1]) or nil
    local digest: string? = prior and bounds.line(prior.digest, 64) or nil
    if not digest then
        local planned = call("plan", REQUEST)
        assert(planned.ok == true, tostring(planned.message))
        local plan = bounds.object(planned.value)
        digest = plan and bounds.line(plan.digest, 64) or nil
    end
    if not digest then error("missing plan digest") end
    local failed = call("apply", REQUEST, digest)
    assert(failed.ok == false and failed.code == "FAILED", tostring(failed.code) .. ": " .. tostring(failed.message))
    local message = bounds.text(failed.message, 4096)
    assert(message and message:find("dependency resolution failed", 1, true) == 1 and message:find("[truncated]", 1, true), "resolver diagnostic was lost")
    local status = installation.status(failed)
    assert(status.status == "failed" and status.code == "FAILED", "definite failure stayed approved")
    local saved = call("status", nil, digest)
    local receipt = bounds.object(saved.value)
    assert(saved.ok == true and receipt and receipt.state == "failed" and receipt.code == "FAILED" and receipt.message == message, "failed receipt was lost")
    local replay = call("apply", REQUEST, digest)
    assert(replay.ok == false and replay.code == "FAILED" and replay.replayed == true and replay.message == message, "failed receipt was not replayed")
    local installed = call("installed")
    local inventory = bounds.object(installed.value)
    local modules = inventory and bounds.array(inventory.modules, 512) or nil
    assert(modules, "invalid installed inventory")
    for _, raw in ipairs(modules) do
        local module = bounds.object(raw)
        assert(not module or module.component ~= "wippy/test", "failed apply installed the module")
    end
    logger:info("HUB_FAILURE_RECEIPT_PASS")
    return 0
end
return {main = main}
'''


def failure_receipt_check(folder):
    import yaml
    probe = folder / "src/hubrecoveryprobe"
    (probe / "main.lua").write_text(FAILURE_PROBE)
    document = yaml.safe_load((probe / "_index.yaml").read_text())
    entry = next(item for item in document["entries"] if item["name"] == "main")
    entry["imports"]["installation"] = "bee.hub.activation:installation"
    document["entries"] = [item for item in document["entries"] if item["name"] in {"policy", "management_policy", "reader_policy", "main"}]
    (probe / "_index.yaml").write_text(yaml.safe_dump(document, sort_keys=False))
    service = folder / "modules/hub/src/binding/publication.lua"
    original = service.read_text()
    injected = '''local function rejected_apply(): (registry.Version?, string?)
    return nil, "dependency resolution failed: acme/worker@1, 2; " .. string.rep("conflicting roots; ", 500)
end
'''
    anchor = "    local applied, apply_error = changes:apply()"
    assert original.count(anchor) == 1
    service.write_text(original.replace('local registry = require("registry")', 'local registry = require("registry")\n' + injected, 1).replace(anchor, "    local applied, apply_error = rejected_apply()"))
    subprocess.run([str(RUNTIME), "lint", "--strict-any", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
                   cwd=folder, env=command_environment(folder), check=True, timeout=120)
    # Both calls boot a new runtime over the same history; the second replays
    # the failed receipt without invoking the rejected dependency operation.
    for _ in range(2):
        result = subprocess.run([str(RUNTIME), "run", "--verbose", "--host", "bee:hub_workers", "--", "hub-recovery-probe"],
                                cwd=folder, env=command_environment(folder), capture_output=True, text=True, timeout=180)
        output = result.stdout + result.stderr
        assert result.returncode == 0 and "HUB_FAILURE_RECEIPT_PASS" in output, output
        print("HUB_FAILURE_RECEIPT_PASS")


def main():
    if not RUNTIME.is_file():
        raise SystemExit(f"candidate runtime {RUNTIME} is unavailable")
    folder = Path(tempfile.mkdtemp(prefix="bee-hub-recovery-"))
    try:
        prepare_fixture(folder)
        failure_folder = folder / "failure-case"
        shutil.copytree(folder, failure_folder, ignore=shutil.ignore_patterns("failure-case"))
        failure_receipt_check(failure_folder)
        service = folder / "modules/hub/src/binding/publication.lua"
        original = service.read_text()
        anchor = "    local applied, apply_error = changes:apply()\n    if not applied then return failed_apply(receipt, apply_error) end\n"
        assert original.count(anchor) == 1, "publication injection anchor is not unique"
        subprocess.run(
            [str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
            cwd=folder,
            env=command_environment(folder),
            check=True,
            timeout=120,
        )
        service.write_text(original.replace(
            anchor,
            anchor + '    print("HUB_RECOVERY_INJECTED_AFTER_PUBLICATION")\n    while true do end\n',
        ))
        kill_after_publication(RUNTIME, folder)
        service.write_text(original)
        conflict_folder = folder / "conflict-case"
        # Runtime is dead; retain its full SQLite state, including any WAL.
        shutil.copytree(folder, conflict_folder, ignore=shutil.ignore_patterns("conflict-case"))
        run(RUNTIME, folder, "hub-recovery-restart")
        run(RUNTIME, conflict_folder, "hub-recovery-tamper")
        run(RUNTIME, conflict_folder, "hub-recovery-conflict")
    except Exception:
        print(f"Hub recovery fixture preserved for inspection: {folder}")
        raise
    else:
        shutil.rmtree(folder)
    print("HUB_RECOVERY_PASS")


if __name__ == "__main__":
    main()

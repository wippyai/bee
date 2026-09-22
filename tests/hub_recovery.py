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
namespace: bee.hub_recovery_probe
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
    bounds: bee.threads.records:bounds
  security:
    policies: [bee.hub_recovery_probe:policy, bee.hub_recovery_probe:management_policy, bee.hub_recovery_probe:reader_policy]
  meta:
    command:
      name: hub-recovery-probe
      security: {actor: {id: bee.hub_recovery_probe}}
- name: restart
  kind: process.lua
  source: file://main.lua
  method: restart
  modules: [funcs, registry, logger]
  imports:
    bounds: bee.threads.records:bounds
  security:
    policies: [bee.hub_recovery_probe:policy, bee.hub_recovery_probe:management_policy, bee.hub_recovery_probe:reader_policy]
  meta:
    command:
      name: hub-recovery-restart
      security: {actor: {id: bee.hub_recovery_probe}}
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
    bounds: bee.threads.records:bounds
  security:
    policies: [bee.hub_recovery_probe:writer_policy]
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
    bounds: bee.threads.records:bounds
  security:
    policies: [bee.hub_recovery_probe:policy, bee.hub_recovery_probe:management_policy, bee.hub_recovery_probe:reader_policy]
  meta:
    command:
      name: hub-recovery-conflict
      security: {actor: {id: bee.hub_recovery_probe}}
'''


def command_environment(folder):
    return {
        "HOME": str(folder / "home"),
        "XDG_CONFIG_HOME": str(folder / "config"),
        "XDG_DATA_HOME": str(folder / "data"),
        "XDG_STATE_HOME": str(folder / "state"),
        "PATH": "/usr/bin:/bin",
        "GOMAXPROCS": "2",
    }


def prepare_fixture(folder):
    # Match the existing live-Hub fixture composition. Production modules are
    # copied into this disposable source tree; none of these files enter src/.
    shutil.copytree(ROOT / "tests/fixtures/hub_manage", folder / "src")
    shutil.copytree(ROOT / "src/hub", folder / "src/hub")
    shutil.copy2(ROOT / "modules/threads/src/records/bounds.lua", folder / "src/records/bounds.lua")
    for name in ("bounds.lua", "canonical.lua"):
        shutil.copy2(ROOT / "modules/sync/src" / name, folder / "src/sync" / name)
    (folder / "src/persist").mkdir()
    shutil.copy2(ROOT / "modules/persist/src/transaction.lua", folder / "src/persist/transaction.lua")
    (folder / "src/persist/_index.yaml").write_text(
        "version: '1.0'\nnamespace: bee.persist\nentries:\n"
        "- name: transaction\n  kind: library.lua\n  source: file://transaction.lua\n  modules: [sql, time]\n"
    )
    (folder / "src/hub_recovery_probe").mkdir()
    (folder / "src/hub_recovery_probe/main.lua").write_text(PROBE)
    (folder / "src/hub_recovery_probe/_index.yaml").write_text(PROBE_INDEX)
    # The runtime requires the repository's source-directory lock. Copy it
    # unchanged into the disposable fixture; this test never edits the lock.
    shutil.copy2(ROOT / "wippy.lock", folder / "wippy.lock")
    (folder / ".wippy.yaml").write_text(
        "version: '1.0'\nregistry:\n  enable_history: true\n"
        "  history_type: sqlite\n  history_path: registry.db\nshutdown:\n  timeout: 2s\n"
    )


def run(runtime, folder, command):
    result = subprocess.run(
        [str(runtime), "run", "--verbose", "--host", "bee:workers", "--", command],
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
        [str(runtime), "run", "--verbose", "--host", "bee:workers", "--", "hub-recovery-probe"],
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


def main():
    if not RUNTIME.is_file():
        raise SystemExit(f"candidate runtime {RUNTIME} is unavailable")
    folder = Path(tempfile.mkdtemp(prefix="bee-hub-recovery-"))
    try:
        prepare_fixture(folder)
        service = folder / "src/hub/service.lua"
        original = service.read_text()
        anchor = "    local applied, apply_error = changes:apply()\n    if not applied then return transaction.failure(\"FAILED\", tostring(apply_error)) end\n"
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

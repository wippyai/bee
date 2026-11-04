"""Compose isolated application fixtures with explicit fault and scheduling seams."""
from pathlib import Path
import fcntl
import gzip
import re
import shutil
import socket
import sys
import textwrap

import yaml

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "tests"
COMPOSITION = TESTS / ".wippy/composition"
# bee/drivers, composed beside Bee from the repository's drivers module.
DRIVERS_COMPOSITION = TESTS / ".wippy/composition-drivers"


def replace_once(path, anchor, replacement):
    text = path.read_text()
    assert text.count(anchor) == 1, f"{path}: anchor must occur once: {anchor!r}"
    path.write_text(text.replace(anchor, replacement))


def update_entries(index, update):
    document = yaml.safe_load(index.read_text())
    update({entry["name"]: entry for entry in document["entries"]})
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def add_modules(index, name, modules):
    def update(entries):
        listed = entries[name].setdefault("modules", [])
        listed.extend(module for module in modules if module not in listed)
    update_entries(index, update)


def message_barrier(controller, report, release, payload, label=None, response="released"):
    import json
    check = f"assert(tostring({response}:from()) == {controller}"
    if label:
        check += ", " + json.dumps(label)
    return "\n".join([
        f'local release = assert(process.listen({json.dumps(release)}, {{message = true}}))',
        f'assert(process.send({controller}, {json.dumps(report)}, {payload}))',
        f'local {response} = assert((release:receive()))', check + ")",
        'process.unlisten(release)',
    ])


def observe_carrier(src):
    """Report carrier steps only to a controller that explicitly opts in."""
    carrier = src / "harness/service/process.lua"
    replace_once(carrier, 'local process = require("process")',
                 'local process = require("process")\nlocal ctx = require("ctx")')
    replace_once(carrier, "    local io = io_for(after)", '''    local observed = after
    after = function(step: string)
        if controller and ctx.get("bee.test.carrier.progress") == true then
            assert(process.send(controller, "bee.test.carrier.progress", step))
        end
        if observed then observed(step) end
    end
    local io = io_for(after)''')
    add_modules(src / "harness/service/_index.yaml", "carrier", ["ctx"])


def hold_attempt_snapshot(src):
    """Hold a native attempt read between its row and its projection for a controller."""
    store = src / "placement/native/persist/store.lua"
    replace_once(store, 'local sql = require("sql")',
                 'local sql = require("sql")\nlocal process = require("process")\nlocal ctx = require("ctx")')
    replace_once(store, "    local attempt, project_error = project(row)", '''    local controller = ctx.get("bee.test.attempt.snapshot")
    if type(controller) == "string" then
''' + textwrap.indent(message_barrier('controller', 'bee.test.attempt.snapshot', 'bee.test.attempt.release', '{attempt_id = attempt_id}', 'attempt snapshot barrier sender', 'released'), " " * 8) + '''
    end
    local attempt, project_error = project(row)''')
    add_modules(src / "placement/native/persist/_index.yaml", "store", ["process", "ctx"])


def gate_runner(src):
    """Expire the drain timer or hold before the child starts when the probe asks."""
    runner = src / "placement/native/service/runner.lua"
    anchor = '    local starting = store.transition(db, attempt_id, {expected_execution = "starting", fields = {runner_pid = process.pid()}, evidence = {kind = "runner.started", detail = "runner " .. process.pid()}})'
    replace_once(runner, anchor, '''    if request.environment.BEE_TEST_CLAIM_CONTROLLER then
        local controller = request.environment.BEE_TEST_CLAIM_CONTROLLER
''' + textwrap.indent(message_barrier('controller', 'bee.test.claim.held', 'bee.test.claim.release',
                                      '{attempt_id = attempt_id}', 'runner claim gate sender'), " " * 8) + '''
    end
''' + anchor)
    replace_once(runner, "    local started, start_error = proc:start()", '''    if request.environment.BEE_TEST_STARTUP_CONTROLLER then
        local controller = request.environment.BEE_TEST_STARTUP_CONTROLLER
''' + textwrap.indent(message_barrier('controller', 'bee.test.runner.held', 'bee.test.runner.release', '{attempt_id = attempt_id}', 'startup gate sender', 'released'), " " * 8) + '''
    end
    local started, start_error = proc:start()''')
    replace_once(runner, "    local stop_requested = false", "    local backpressure_reported = false\n    local stop_requested = false")
    replace_once(runner, '    local drain_timer = time.after("1ms")', '''    local drain_controller = request.environment.BEE_TEST_DRAIN_CONTROLLER
    local drain_instant = time.unix(0, 0)
    local function drain_now()
        return drain_controller and drain_instant or time.now()
    end
    local drain_timer = drain_controller and channel.new(1) or time.after("1ms")
    local drain_proved = false''')
    replace_once(runner, '    local drain_started = time.now()', '    local drain_started = drain_now()')
    replace_once(runner, '            drain_started = time.now()', '            drain_started = drain_now()')
    replace_once(runner, 'time.now():sub(drain_started):milliseconds()', 'drain_now():sub(drain_started):milliseconds()')
    replace_once(runner, '            drain_timer = time.after(tostring(math.max(1, drain_remaining)) .. "ms")',
                 '            drain_timer = drain_controller and channel.new(1) or time.after(tostring(math.max(1, drain_remaining)) .. "ms")')
    replace_once(runner, '        local cases = {controls:case_receive(), inputs:case_receive(), acks:case_receive(), events:case_receive(), exits:case_receive()}', '''        if drain_controller and exited and reads_paused and not drain_proved then
            drain_proved = true
            drain_instant = drain_instant:add("10s")
            assert(process.send(drain_controller, "bee.test.drain.paused", {attempt_id = attempt_id,
                remaining = drain_remaining, armed = drain_armed, spooled = spooled}))
        end
        local cases = {controls:case_receive(), inputs:case_receive(), acks:case_receive(), events:case_receive(), exits:case_receive()}''')

    replace_once(runner, "        local reads_paused = spooled >= protocol.MAX_SPOOL_BYTES", '''        local reads_paused = spooled >= protocol.MAX_SPOOL_BYTES
        if reads_paused and not backpressure_reported and request.environment.BEE_TEST_BACKPRESSURE_CONTROLLER then
            backpressure_reported = true
            assert(process.send(request.environment.BEE_TEST_BACKPRESSURE_CONTROLLER,
                "bee.test.native.backpressure", {attempt_id = attempt_id, spooled = spooled}))
        end''')
    replace_once(runner, "selected = channel.select(cases)", '''selected = channel.select(drain_armed and not drain_expired and request.environment.PROBE_VALUE == "expire-pipe"
            and {drain_timer:case_receive()} or cases)''')
    replace_once(runner, "    local started, start_error = proc:start()", '''    if request.environment.PROBE_VALUE == "hold-retention" then
''' + textwrap.indent(message_barrier('assert(recipient)', 'bee.test.native.held',
                                      'bee.test.native.release', '{attempt_id = attempt_id}', 'retention gate sender'), " " * 8) + '''
    end
    local started, start_error = proc:start()''')
    replace_once(runner, '    local retain_timer = time.after("1ms")', '''    local retain_timer = request.environment.BEE_TEST_RETENTION_CONTROLLER
        and assert(process.listen("bee.test.retention.expire", {message = true})) or time.after("1ms")''')
    replace_once(runner, '            retain_timer = time.after(tostring(request.timeouts.retain_ms) .. "ms")', '''            local controller = request.environment.BEE_TEST_RETENTION_CONTROLLER
            if controller then
                assert(process.send(controller, "bee.test.retention.armed", {attempt_id = attempt_id}))
            else
                retain_timer = time.after(tostring(request.timeouts.retain_ms) .. "ms")
            end''')


def gate_attachment(src):
    """Select a fence deadline while the runner is held before or after installation."""
    service = src / "placement/native/service/service.lua"
    replace_once(service, 'local process = require("process")',
                 'local process = require("process")\nlocal ctx = require("ctx")')
    replace_once(service, '        while awaiting_start do', '''        local startup_controller = ctx.get("bee.test.attach.controller")
        if awaiting_start and type(startup_controller) == "string" then
            assert(process.send(startup_controller, "bee.test.attach.held", {phase = "startup"}))
        end
        while awaiting_start do''')
    replace_once(service, '        local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")', '''        local controller = ctx.get("bee.test.attach.controller")
        local timer = type(controller) == "string" and assert(process.listen("bee.test.attach.timeout", {message = true}))
            or time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
        if type(controller) == "string" then
            assert(process.send(controller, "bee.test.attach.held", {phase = "waiting"}))
        end''')
    replace_once(service, '        process.unlisten(fences)', '''        process.unlisten(fences)
        if type(controller) == "string" then process.unlisten(timer) end''')
    add_modules(src / "placement/native/service/_index.yaml", "service", ["ctx"])
    runner = src / "placement/native/service/runner.lua"
    for phase, anchor in [
        ("before", '                    if next_generation > generation then'),
        ("after", '                    process.send(tostring(message:from()), protocol.TOPIC_FENCED, {attempt_id = attempt_id, generation = next_generation,')
    ]:
        replace_once(runner, anchor, '''                    if request.environment.BEE_TEST_FENCE_PHASE == "''' + phase + '''" then
                        local controller = assert(request.environment.BEE_TEST_FENCE_CONTROLLER)
''' + textwrap.indent(message_barrier('controller', 'bee.test.attach.held', 'bee.test.attach.release', '{phase = "' + phase + '"}', 'attachment barrier sender'), ' ' * 24) + '''
                    end
''' + anchor)


def managed_gateway(src):
    """Point the gateway listener, its endpoint and its readiness grant at one free loopback port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{listener.getsockname()[1]}"

    def listen(entries):
        entries["gateway_endpoint"]["data"]["address"] = address
    update_entries(src / "gateway/api/_index.yaml", listen)

    def bind(entries):
        entries["gateway_listener"]["addr"] = address
    update_entries(src / "_index.yaml", bind)

    def pin(entries):
        entries["readiness_policy"]["policy"]["expression"] = (
            '(action == "http_client.private_ip" && resource == "127.0.0.1") || '
            f'(action == "http_client.request" && resource == "http://{address}/ready")')
    update_entries(src / "gateway/security/_index.yaml", pin)


def runner_fixture_type(src):
    """The runner finds the fixture applications' tests by their own type, so the suites' unrestricted runner leaves them alone."""
    source = src / "hub/binding/artifact_source.lua"
    replace_once(source, 'local M = {}', 'local fixture_catalog = require("fixture_catalog")\nlocal M = {}')
    replace_once(source, '    return {versions = catalog.available,', '    if target == "bee/progress" then return fixture_catalog.source() end\n    return {versions = catalog.available,')
    index = src / "hub/binding/_index.yaml"
    text = index.read_text()
    anchor = text.index("- name: artifact_source\n")
    index.write_text(text[:anchor] + text[anchor:].replace("  imports:\n", "  imports:\n    fixture_catalog: bee.tests.gov:hub_fixture_catalog\n", 1))
    inspect = src / "hub/binding/inspect.lua"
    replace_once(inspect, 'local M = {}', 'local fixture_catalog = require("fixture_catalog")\nlocal M = {}')
    replace_once(inspect, '    if not request then return nil, request_error end', '''    if not request then return nil, request_error end
    if request.component == "bee/progress" then
        local selected, problem = fixture_catalog.source().artifact(request.component, request.version)
        if not selected then return nil, problem end
        local configured, invalid = requirements.read(selected.entries, request.parameters)
        if not configured then return nil, invalid end
        local page = complete and {entries = selected.entries, next_offset = nil, eof = true}
            or inspection.page(selected.entries, request.entry_offset, request.entry_limit, request.include_data)
        return {component = selected.component, version = selected.version, digest = selected.digest,
            entries = page.entries, requirements = configured, metadata = selected.metadata,
            next_offset = page.next_offset, eof = page.eof}, nil
    end''')
    text = index.read_text()
    anchor = text.index("- name: inspect\n")
    index.write_text(text[:anchor] + text[anchor:].replace("  imports:\n", "  imports:\n    fixture_catalog: bee.tests.gov:hub_fixture_catalog\n", 1))
    catalog = src / "hub/binding/catalog.lua"
    transport = src / "hub/binding/catalog_transport.lua"
    transport.write_text(catalog.read_text().replace('local hub = require("hub")', 'local hub = require("fixture_hub")'))
    with index.open("a") as stream:
        stream.write('''
- name: catalog_transport
  kind: library.lua
  source: file://catalog_transport.lua
  modules: [registry, store]
  imports:
    fixture_hub: bee.tests.hub:catalog_fixture
    bounds: bee.drivers.values:bounds
    limits: bee.hub.package:limits
''')
    replace_once(catalog, 'local hub = require("hub")', 'local hub = require("fixture_hub")')
    text = index.read_text()
    anchor = text.index("- name: catalog\n")
    index.write_text(text[:anchor] + text[anchor:].replace("  imports:\n", "  imports:\n    fixture_hub: bee.tests.hub:catalog_fixture\n", 1))
    replace_once(catalog, '    local response, response_error', '''    if request.query == "fixture-unavailable" then return nil, "fixture catalog unavailable" end
    if request.query == "fixture-long-failure" then return nil, string.rep("dependency unavailable; ", 300) .. "\\nreason-end" end
    if request.query == nil or request.query == "progress" then
        return {items = {{component = "bee/progress", title = "Progress", description = "Task tracking",
            latest_version = "1.0.0", application = true}}, total = 1, page = request.page, page_size = M.PAGE_SIZE}, nil
    end
    local response, response_error''')
    replace_once(catalog, '    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})', '''    if request.component == "bee/progress" then
        return {component = request.component, latest_version = "1.0.0", title = "Progress", description = "Task tracking",
            readme = "", readme_error = "fixture README unavailable", versions = {{version = "1.0.0", yanked = false},
                {version = "9.0.0", yanked = false}, {version = "2.0.0", yanked = false}}, total_versions = 3, page = request.page, page_size = M.MAX_VERSIONS}, nil
    end
    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})''')
    replace_once(src / "node/application_tests.lua", 'meta.type == "test"', 'meta.type == "app_test"')


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    environment["data"]["values"]["opencode"] = str(TESTS / "fixtures/harness/bin/opencode")
    target = COMPOSITION / "src/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


def observe_preparer_cleanup(src):
    replace_once(src / "placement/native/service/workdir_preparers.lua",
                 "    local taken, take_error = process.registry.register(lock)\n    if not taken then",
                 """local fixture = registry.get("bee.tests.placement.native:preparer_fixture_config")
    if fixture and fixture.data and type(fixture.data.cleanup_observer) == "string" then
        assert(process.send(fixture.data.cleanup_observer, "bee.test.preparer.observed", {}))
    end
    if fixture and fixture.data and type(fixture.data.cleanup_gate) == "string" then
""" + textwrap.indent(message_barrier('fixture.data.cleanup_gate', 'bee.test.preparer.gate', 'bee.test.preparer.gate.release',
                                      '{}', 'cleanup gate sender', 'opened'), " " * 8) + """
    end
    local taken, take_error = process.registry.register(lock)
    if not taken then""")
    replace_once(src / "placement/native/service/workdir_preparers.lua",
                 'local db, open_error = store.open()\n    if not db then return false, open_error end\n    local plans, plans_error = store.preparer_plans(db, attempt.attempt_id)',
                 '''local fixture = registry.get("bee.tests.placement.native:preparer_fixture_config")
    if fixture and fixture.data and fixture.data.cleanup_crash_attempt == attempt.attempt_id and type(fixture.data.cleanup_crash) == "string" then
        local crash = assert(process.listen("bee.test.preparer.crash", {message = true}))
        assert(process.send(fixture.data.cleanup_crash, "bee.test.preparer.claimed", {}))
        assert((crash:receive()))
        error("fixture cleanup owner crashed")
    end
    local db, open_error = store.open()
    if not db then return false, open_error end
    local plans, plans_error = store.preparer_plans(db, attempt.attempt_id)''')
    # A follower reports the holder it found and stays there until the
    # controller releases it, so the holder can end before the follower waits.
    replace_once(src / "placement/native/service/workdir_preparers.lua",
                 "        if follow then\n",
                 """        if follow then
            local waiting = registry.get("bee.tests.placement.native:preparer_fixture_config")
            if waiting and waiting.data and type(waiting.data.cleanup_waiter) == "string" then
""" + textwrap.indent(message_barrier('waiting.data.cleanup_waiter', 'bee.test.preparer.waiting', 'bee.test.preparer.proceed',
                                      '{holder = tostring(holder)}', 'follower barrier sender', 'proceed'), " " * 16) + """
            end
""")


def hold_docker_cleanup(src):
    """Order caller snapshots and committed cleanup outcomes with the owner."""
    methods = src / "placement/docker/binding/methods.lua"
    replace_once(methods, 'local cdc = require("cdc")',
                 'local cdc = require("cdc")\nlocal ctx = require("ctx")')
    add_modules(src / "placement/docker/binding/_index.yaml", "methods", ["ctx"])
    replace_once(methods,
                 "function M.cleanup_loaded(loaded: Loaded): Reply",
                 """function M.cleanup_loaded(loaded: Loaded): Reply
    local controller = process.registry.lookup("bee.test.docker.cleanup")
    if controller then
""" + textwrap.indent(message_barrier('tostring(controller)', 'bee.test.docker.cleanup', 'bee.test.docker.cleanup.release', '{attempt_id = loaded.attempt.attempt_id}', None, 'message'), " " * 8) + """
        local response = bounds.object(message:payload():data())
        if response and response.fail == true then return fail("UNAVAILABLE", "fixture cleanup refusal") end
    end""")
    replace_once(methods,
                 '            if current.attempt.cleanup_state == "complete" then return succeed(current.attempt) end',
                 '''            if current.attempt.cleanup_state == "complete" then return succeed(current.attempt) end
            local controller = ctx.get("bee.test.docker.cleanup.snapshot")
            if type(controller) == "string" then
''' + textwrap.indent(message_barrier('controller', 'bee.test.docker.cleanup.snapshot',
                                      'bee.test.docker.cleanup.resume', '{attempt_id = current.attempt.attempt_id}'), " " * 16) + '''
            end''')
    replace_once(methods, '                if not recorded.ok then return recorded end\n                failure = failure or result',
                 '''                if not recorded.ok then return recorded end
                local controller = process.registry.lookup("bee.test.docker.cleanup.outcome")
                if controller then
''' + textwrap.indent(message_barrier('tostring(controller)', 'bee.test.docker.cleanup.outcome',
                                      'bee.test.docker.cleanup.continue', '{}'), " " * 20) + '''
                end
                failure = failure or result''')


def advance_committed_transition(src):
    boundary = '''        return {ok = false, code = "STORAGE", message = "commit transition"}
    end'''
    replace_once(src / "placement/native/persist/store.lua", boundary, boundary + '''
    if update.evidence.kind == "test.transition_snapshot" then
        assert(M.transition(db, attempt_id, {cleanup = "complete",
            evidence = {kind = "test.transition_advanced", detail = "subsequent committed transition"}}).ok)
    end''')


def observe_sync_idle(src):
    path = src / "sync/service/service.lua"
    replace_once(path, "stopped: boolean}", "stopped: boolean, pending: boolean?, busy: boolean?}")
    replace_once(path, "    local function run(worker: Worker)", """    local observed_workers: {Worker} = {}
    local observer: {pid: string, topic: string}? = nil
    local function idle()
        if not observer then return end
        for _, worker in ipairs(observed_workers) do
            if worker.pending or worker.busy then return end
        end
        local reply = observer
        observer = nil
        assert(process.send(reply.pid, reply.topic, {}))
    end
    local function run(worker: Worker)""")
    replace_once(path, "            if not ok or worker.stopped then return end", "            if not ok or worker.stopped then worker.pending, worker.busy = false, false; idle(); return end\n            worker.pending, worker.busy = false, true")
    replace_once(path, "    local function wake(worker: Worker)\n", "    local function wake(worker: Worker)\n        worker.pending = true\n")
    replace_once(path, "            end\n        end\n    end\n\n    local function wake", "            end\n            worker.busy = false\n            idle()\n        end\n    end\n\n    local function wake")
    replace_once(path, "                workers[key] = worker", "                workers[key] = worker\n                observed_workers[#observed_workers + 1] = worker")
    replace_once(path, "    local exports = assert(load())", '    local inspection = assert(process.listen("bee.test.sync.idle", {message = true}))\n    local exports = assert(load())' )
    replace_once(path, "joins:case_receive(), departures:case_receive(), registry_changes:case_receive()}", "joins:case_receive(), departures:case_receive(), registry_changes:case_receive(), inspection:case_receive()}")
    replace_once(path, "        if selected.channel == lifecycle then", """        if selected.channel == inspection then
            local message = selected.value
            local controller = process.registry.lookup("bee.test.hygiene", process.registry.LOCAL)
            local data = message:payload():data()
            assert(controller and tostring(controller) == tostring(message:from()) and type(data) == "table" and type(data.topic) == "string")
            while true do
                local change = channel.select({registry_changes:case_receive(), default = true})
                if change.default then break end
                assert(change.ok, "registry observation ended")
            end
            exports = assert(load())
            assert(not refresh())
            observer = {pid = tostring(message:from()), topic = data.topic}
            idle()
        elseif selected.channel == lifecycle then""")


def fixture_hub_updates(src):
    index = src / "hub/binding/_index.yaml"
    document = yaml.safe_load(index.read_text())
    for name in ("updates", "publication", "inspect"):
        path = src / f"hub/binding/{name}.lua"
        replace_once(path, 'local M = {}', 'local update_fixture = require("update_fixture")\nlocal M = {}')
        if name == "inspect":
            replace_once(path, 'hub.versions.open(request.component, request.version, {timeout = 30})',
                         'update_fixture.versions.open(request.component, request.version, {timeout = 30})')
        else:
            text = path.read_text().replace("registry.snapshot()", "update_fixture.snapshot()", 1)
            path.write_text(text)
        entry = next(entry for entry in document["entries"] if entry["name"] == name)
        entry["imports"]["update_fixture"] = "bee.tests.hub:update_fixture"
    index.write_text(yaml.safe_dump(document, sort_keys=False))


def compose_root_pack():
    """Expand the immutable published package snapshot for the Lua inspection suites."""
    encoded = gzip.decompress((TESTS / "fixtures/hub/root_pack.json.gz").read_bytes()).decode()
    assert "]====]" not in encoded
    (TESTS / "lua/hub/root_pack_data.lua").write_text(
        "return {encoded = [====[" + encoded + "]====]}\n")


def compose():
    compose_root_pack()
    shutil.rmtree(COMPOSITION, ignore_errors=True)
    shutil.rmtree(DRIVERS_COMPOSITION, ignore_errors=True)
    src = COMPOSITION / "src"
    shutil.copytree(ROOT / "src", src)
    shutil.copytree(ROOT / "drivers/src", DRIVERS_COMPOSITION)
    # The composition is a module root like the repository: its manifest
    # beside src, so module-relative directories resolve as they do in a pack.
    shutil.copy(ROOT / "wippy.yaml", COMPOSITION / "wippy.yaml")
    hold_docker_cleanup(src)
    advance_committed_transition(src)
    observe_preparer_cleanup(src)
    observe_sync_idle(src)
    observe_carrier(src)
    hold_attempt_snapshot(src)
    gate_runner(src)
    gate_attachment(src)
    shutil.copytree(TESTS / "fixtures/memory", src / "test_memory")
    shutil.copytree(TESTS / "fixtures/persist/retained", src / "test_retained")
    managed_gateway(src)
    runner_fixture_type(src)
    fixture_hub_updates(src)
    shutil.copy2(ROOT / "src/placement/native/service/materialization.lua",
                 TESTS / "lua/placement/native/service/materialization.lua")
    shutil.copy2(ROOT / "src/placement/docker/service/image_owner.lua",
                 TESTS / "lua/placement/docker/service/image_owner.lua")
    shutil.copy2(ROOT / "src/gov/service/activation_worker.lua",
                 TESTS / "lua/gov/activation_worker.lua")
    shutil.copy2(ROOT / "src/process/demand_owner.lua",
                 TESTS / "lua/process/demand_owner.lua")
    host_environment()


def main():
    (TESTS / ".wippy").mkdir(exist_ok=True)
    with (TESTS / ".wippy/composition.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        compose()


if __name__ == "__main__":
    sys.exit(main())

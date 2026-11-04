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


def observe_hook_cancellation(src):
    supervisor = src / "threads/hooks/supervisor.lua"
    replace_once(supervisor, 'local funcs = require("funcs")',
        'local funcs = require("funcs")\nlocal events = require("events")')
    replace_once(supervisor, '    pending.future:cancel()',
        '    pending.future:cancel()\n    events.send("bee.test.hook/" .. pending.id, "cancelled", pending.id, {cancelled = pending.future:is_canceled()})')
    add_modules(src / "threads/hooks/_index.yaml", "supervisor", ["events"])


def fixture_clock(src):
    """The gateway reads the time from a fixture instant a suite may pin."""
    shutil.copytree(TESTS / "fixtures/gateway_clock", src / "gateway_clock")
    for name in ("values", "listener", "capabilities", "credentials"):
        gateway = src / "gateway/binding" / (name + ".lua")
        if "time.now()" not in gateway.read_text():
            continue
        replace_once(gateway, 'local time = require("time")',
                     'local time = require("time")\nlocal fixture_clock = require("fixture_clock")')
        gateway.write_text(gateway.read_text().replace("time.now()", "fixture_clock.now()"))
        update_entries(src / "gateway/binding/_index.yaml",
                       lambda entries: entries[name]["imports"].update(
                           {"fixture_clock": "bee.gateway:fixture_clock"}))

    hooks = src / "threads/hooks/supervisor.lua"
    text = hooks.read_text()
    if "time.now():unix_nano()" in text:
        hooks.write_text(text.replace('local time = require("time")',
            'local time = require("time")\nlocal fixture_clock = require("fixture_clock")')
            .replace("time.now():unix_nano()", "fixture_clock.wall_nanoseconds()"))
        update_entries(src / "threads/hooks/_index.yaml",
            lambda entries: entries["supervisor"].setdefault("imports", {}).update(
                {"fixture_clock": "bee.gateway:fixture_clock"}))

    def read_instant(entries):
        policy = entries["store_policy"]["policy"]
        policy["actions"].append("registry.get")
        policy["resources"].append("bee.gateway:fixture_instant")
    update_entries(src / "gateway/security/_index.yaml", read_instant)


def credential_clock(src):
    """Credential lease tests select an instant in their function context."""
    broker = src / "credentials/binding/broker.lua"
    broker.write_text(broker.read_text().replace('clock.milliseconds()', 'milliseconds()'))
    replace_once(broker, 'local clock = require("clock")', '''local clock = require("clock")
local ctx = require("ctx")
local function milliseconds(): integer
    local instant = ctx.get("bee.test.credentials.milliseconds")
    if instant == nil then return clock.milliseconds() end
    assert(type(instant) == "number" and math.tointeger(instant), "credential fixture instant")
    return math.floor(instant)
end''')
    def imports(entries):
        for entry in entries.values():
            if entry.get("source") == "file://broker.lua":
                modules = entry.setdefault("modules", [])
                if "ctx" not in modules:
                    modules.append("ctx")
    update_entries(src / "credentials/binding/_index.yaml", imports)


def resource_clock(src):
    """Resource callers and background supervision read the same fixture instant."""
    shutil.copytree(TESTS / "fixtures/resource_clock", src / "resource_clock")
    authority = src / "resources/persist/authority.lua"
    replace_once(authority, 'local clock = require("clock")',
                 'local clock = require("clock")\nlocal fixture_clock = require("fixture_clock")')
    authority.write_text(authority.read_text().replace('clock.milliseconds()', 'fixture_clock.milliseconds()'))
    def imports(entries):
        entries["authority"]["imports"]["fixture_clock"] = "bee.resources:fixture_clock"
    update_entries(src / "resources/persist/_index.yaml", imports)


def yield_session_defaults(src):
    """The Sessions SDK suites select their synthetic contract owners as the defaults."""
    def yield_defaults(entries):
        for name in ("owner_binding", "catalog_binding"):
            for contract in entries[name]["contracts"]:
                contract["default"] = False
    update_entries(src / "threads/sessions/binding/_index.yaml", yield_defaults)


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


def malformed_overlay_listing(src):
    """The fixture actor `overlay-listing-fault` receives a malformed overlay list from the overlay call the tests facade makes."""
    source = src / "node/binding/tests_call.lua"
    replace_once(source, 'local function overlays()', '''local function listing(): string
    local actor = security.actor()
    if actor and actor:id() == "overlay-listing-fault" then return "bee.tests.node:overlay_listing_fault" end
    return OVERLAYS
end

local function overlays()''')
    replace_once(source, 'funcs.new():call(OVERLAYS, {operation = "list"})', 'funcs.new():call(listing(), {operation = "list"})')


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    environment["data"]["values"]["opencode"] = str(TESTS / "fixtures/harness/bin/opencode")
    target = COMPOSITION / "src/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


def gate_retired_display(src):
    replace_once(src / "node/service/owner.lua", '    local function stop(instance: Instance): protocol.Reply', '''    local function stop(instance: Instance): protocol.Reply
        local controller = process.registry.lookup("bee.test.retired.cancel", process.registry.LOCAL)
        if controller then
            local release = assert(process.listen("bee.test.retired.release", {message = true}))
            assert(process.send(tostring(controller), "bee.test.retired.held", {id = instance.id}))
            assert(tostring(assert((release:receive())):from()) == tostring(controller))
            process.unlisten(release)
        end''')
    jobs = src / "shell/jobs.lua"
    shell = src / "shell/shell.lua"
    replace_once(jobs, '    local function attach_job(id: string, shown: string): Result', '''    local function retirement_gate(op: string, id: unknown)
        local controller = process.registry.lookup("bee.test.retired." .. op, process.registry.LOCAL)
        if not controller then return end
        local release = assert(process.listen("bee.test.retired.release", {message = true}))
        assert(process.send(tostring(controller), "bee.test.retired.held", {id = id}))
        assert(tostring(assert((release:receive())):from()) == tostring(controller))
        process.unlisten(release)
    end
    local function attach_job(id: string, shown: string): Result
        retirement_gate("attach", id)''')
    replace_once(jobs, '    local function call_job(op: string, args: {[string]: unknown}): Result',
                 '    local function call_job(op: string, args: {[string]: unknown}): Result\n        retirement_gate(op, args.id)')
    replace_once(shell, '    local function node_event(event: client.Event)', '''    local function retired_observed()
        local observer = process.registry.lookup("bee.test.retired.closed", process.registry.LOCAL)
        if observer then assert(process.send(tostring(observer), "bee.test.retired.closed", {})) end
    end
    local function node_event(event: client.Event)
        if event.kind == "closed" and process.registry.lookup("bee.test.retired.drop", process.registry.LOCAL) then
            retired_observed()
            return
        end''')
    replace_once(shell, '            retire(id)', '            retire(id)\n            retired_observed()')
    replace_once(shell, '            apply(chosen.value)', '''            apply(chosen.value)
            local observer = process.registry.lookup("bee.test.retired.applied", process.registry.LOCAL)
            if observer and (chosen.value.kind == "failed" or chosen.value.kind == "retired" or chosen.value.kind == "done") then
                paint()
                assert(process.send(tostring(observer), "bee.test.retired.applied", {status = status, running = running, kind = chosen.value.kind}))
            end''')
    replace_once(shell, '    local function handle(chosen: channel.SelectResult): boolean',
                 '    local move_requests = assert(process.listen("bee.test.retired.move", {message = true}))\n    local function handle(chosen: channel.SelectResult): boolean')
    replace_once(shell, '        if chosen.channel == alert_fade then', '''        if chosen.channel == move_requests then
            local args = chosen.value:payload():data()
            run(function(): Result return call_job("move", args) end)
        elseif chosen.channel == alert_fade then''')
    replace_once(shell, '        local quit = handle(channel.select(cases()))',
                 '        local waiting = cases()\n        waiting[#waiting + 1] = move_requests:case_receive()\n        local quit = handle(channel.select(waiting))')


def observe_node_ready(src):
    replace_once(src / "node/service/owner.lua", '    logger:info("Node ready",',
                 '\n'.join(['    local observer = process.registry.lookup("bee.test.node.ready", process.registry.LOCAL)',
                            '    if observer then assert(process.send(tostring(observer), "bee.test.node.ready", {})) end',
                            '    logger:info("Node ready",']))


def compose_thread_recovery():
    service = (ROOT / "src/threads/service/service.lua").read_text()
    store = service.split("local function with_store", 1)[1].split("local function retire_aliases", 1)[0]
    recovery = service.split("local function recover_commits", 1)[1].split("local function forward", 1)[0]
    (TESTS / "lua/threads/recovery.lua").write_text(
        '-- SPDX-License-Identifier: MIT\nlocal sql = require("runtime")\nlocal database = sql\nlocal notices = sql\nlocal eventbus = sql\n'
        'local logger = require("logger")\nlocal commits = require("commits")\n'
        + "local function with_store" + store + "local function recover_commits" + recovery
        + "return {recover = recover_commits}\n")

    cancellation = service.split('    local lifecycle = assert(process.events())', 1)[1].split('    local handled, problem = pcall(run, active, stopped)', 1)[0]
    (TESTS / "lua/threads/recovery_worker.lua").write_text(
        '-- SPDX-License-Identifier: MIT\nlocal process = require("process")\nlocal channel = require("channel")\n'
        'local runtime = require("runtime")\nlocal recovery = require("recovery")\n'
        'local function main(controller: string)\n    local lifecycle = assert(process.events())' + cancellation
        + '    runtime.reset()\n    runtime.controller = controller\n    recovery.recover(active)\n    lifecycle:close()\n'
        '    assert(process.send(controller, "bee.test.recovery.done", '
        '{settled = runtime.settled, announced = runtime.announced, released = runtime.released}))\nend\nreturn {main = main}\n')


def fail_owner_registry_reads(src):
    """Fail the node owner's installed app, menu and theme reads while a controller holds the failure name."""
    owner = src / "node/service/catalog.lua"
    text = owner.read_text()
    assert text.count("registry.find(") == 4, f"{owner}: expected four registry reads"
    text = text.replace("registry.find(", "find_installed(")
    owner.write_text(text)
    replace_once(owner, 'local registry = require("registry")', '''local registry = require("registry")
local process = require("process")
local function find_installed(filter)
    local controller = process.registry.lookup("bee.test.node.registry_failure", process.registry.LOCAL)
    if controller then
        process.send(tostring(controller), "bee.test.node.registry_failed", {pid = tostring(process.pid())})
        return nil, "injected registry failure"
    end
    return registry.find(filter)
end''')

    add_modules(src / "node/service/_index.yaml", "catalog", ["process"])


def hold_test_runner_quiet(src):
    replace_once(src / "node/service/tests.lua",
                 "if #waiting == 0 then assert(demand.quiet(tests.NAME, generation)) else sweep() end",
                 """if #waiting == 0 then
                local controller = process.registry.lookup("bee.test.node.quiet", process.registry.LOCAL)
                if controller then
                    local release = assert(process.listen("bee.test.node.quiet.release", {message = true}))
                    assert(process.send(tostring(controller), "bee.test.node.quiet", {}))
                    while true do
                        local selected = channel.select({release:case_receive(), lifecycle:case_receive()})
                        if not selected.ok or (selected.channel == lifecycle and selected.value.kind == process.event.CANCEL) then
                            process.unlisten(release)
                            return
                        end
                        if selected.channel == release then
                            assert(tostring(selected.value:from()) == tostring(controller))
                            break
                        end
                    end
                    process.unlisten(release)
                end
                assert(demand.quiet(tests.NAME, generation))
            else sweep() end""")


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


def observe_boot_recovery(src):
    shutil.copy2(TESTS / "lua/gov/recovery_trace.lua", src / "gov/service/recovery_trace.lua")
    shutil.copy2(TESTS / "lua/gov/recovery_trace_schema.lua", src / "gov/service/recovery_trace_schema.lua")
    replace_once(src / "gov/service/recovery.lua", 'local logger = require("logger")',
                 'local trace = require("trace")\nlocal logger = require("logger")')
    replace_once(src / "gov/service/recovery.lua", "local function main()", "local function main()\n    trace.record()")
    path = src / "gov/service/_index.yaml"
    document = yaml.safe_load(path.read_text())
    next(entry for entry in document["entries"] if entry["name"] == "recovery")["imports"]["trace"] = "bee.gov.service:recovery_trace"
    document["entries"].append({"name": "recovery_trace", "kind": "library.lua", "source": "file://recovery_trace.lua", "modules": ["sql"], "meta": {"type": "test_support"}})
    document["entries"].append({"name": "recovery_trace_schema", "kind": "function.lua", "source": "file://recovery_trace_schema.lua", "method": "run",
                                "imports": {"migration": "wippy.migration:migration"},
                                "meta": {"type": "migration", "target_db": "bee:db", "timestamp": "2026-10-12T00:00:00Z", "test_support": True}})
    path.write_text(yaml.safe_dump(document, sort_keys=False))


def inject_registry_faults(src):
    """Fail one named registry read for a caller that opts in through ctx."""
    pumping = src / "threads/service/pump_config.lua"
    replace_once(pumping, 'local registry = require("registry")',
                 'local registry = require("registry")\nlocal ctx = require("ctx")')
    replace_once(pumping, '    local owners, find_error = registry.find({["meta.type"] = "bee.threads.owner"})',
                 '''    local owners, find_error = registry.find({["meta.type"] = "bee.threads.owner"})
    if ctx.get("bee.test.registry.fault") == "bee.threads.owner" then owners, find_error = nil, "registry unavailable" end''')
    add_modules(src / "threads/service/_index.yaml", "pump_config", ["ctx"])


def settings_area_fixture(src):
    """Offer an adversarial catalog area through the real Settings form."""
    model = src / "apps/settings/app/edit_mode.lua"
    replace_once(model, 'local M = {}', 'local ctx = require("ctx")\nlocal M = {}')
    replace_once(model, 'function M.enable(state: State)', '''function M.enable(state: State)
    local area = ctx.get("bee.test.settings.area")
    if type(area) == "string" then state.areas = {{id = area, title = "Test area"}} end''')
    add_modules(src / "apps/settings/app/_index.yaml", "edit_mode", ["ctx"])


def hold_inbox_review(src):
    """Queue input while the first opened card has not reached its display."""
    app = src / "approvals/inbox/app/app.lua"
    replace_once(app, 'local tty = require("tty")', 'local tty = require("tty")\nlocal ctx = require("ctx")')
    replace_once(app, '    while running do', '    local review_held = false\n    while running do')
    replace_once(app, '                local drawn = view.draw', '                local controller = ctx.get("bee.test.inbox.review")\n                if state.detail and not review_held and type(controller) == "string" then\n                    review_held = true\n' + textwrap.indent(message_barrier('controller', 'bee.test.inbox.review', 'bee.test.inbox.display', '{}', 'inbox display barrier sender'), " " * 20) + '\n                end\n                local drawn = view.draw')
    replace_once(app, '    local function act(kind: string, ttl_ms: integer?, gesture: string?)', '    local function act(kind: string, ttl_ms: integer?, gesture: string?)\n        local controller = ctx.get("bee.test.inbox.review")\n        if type(controller) == "string" then\n            assert(process.send(controller, "bee.test.inbox.decide", {approval_id = state.selected, kind = kind}))\n        end')
    add_modules(src / "approvals/inbox/app/_index.yaml", "app", ["ctx"])


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
    hold_test_runner_quiet(src)
    fail_owner_registry_reads(src)
    compose_thread_recovery()
    gate_retired_display(src)
    observe_node_ready(src)
    inject_registry_faults(src)
    hold_docker_cleanup(src)
    advance_committed_transition(src)
    observe_preparer_cleanup(src)
    observe_sync_idle(src)
    observe_boot_recovery(src)
    observe_carrier(src)
    hold_attempt_snapshot(src)
    gate_runner(src)
    gate_attachment(src)
    fixture_clock(src)
    credential_clock(src)
    resource_clock(src)
    observe_hook_cancellation(src)
    shutil.copytree(TESTS / "fixtures/memory", src / "test_memory")
    shutil.copytree(TESTS / "fixtures/persist/retained", src / "test_retained")
    yield_session_defaults(src)
    managed_gateway(src)
    malformed_overlay_listing(src)
    settings_area_fixture(src)
    hold_inbox_review(src)
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

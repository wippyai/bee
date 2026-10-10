"""Compose the copy of the application the Lua suites run against.

The suites load bee/bee from the module root tests/.wippy/composition. The copy carries
test-only seams that never enter src or a pack: the carrier reports its steps
to a controller that opts in through ctx, the native placement store holds an
attempt snapshot behind a barrier, the native runner can expire its drain
timer or hold before it starts the child, the gateway reads its clock from a
fixture instant, and the Sessions owner and catalog bindings yield the
contract defaults to the suites' synthetic owners. The placement publication
suite compiles the current native materialization source against its test
homes, the host environment the suites read names the Claude protocol
fixture as the installed claude executable, the gateway listens on one
selected loopback port the suites open explicitly, and the node's test runner
finds the fixture applications' tests by a type the suites' own runner skips.
"""
from pathlib import Path
import shutil
import socket
import sys

import yaml

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
COMPOSITION = TESTS / ".wippy/composition"


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
        local release = assert(process.listen("bee.test.attempt.release", {message = true}))
        assert(process.send(controller, "bee.test.attempt.snapshot", {attempt_id = attempt_id}))
        local released = assert((release:receive()))
        assert(tostring(released:from()) == controller, "attempt snapshot barrier sender")
        process.unlisten(release)
    end
    local attempt, project_error = project(row)''')
    add_modules(src / "placement/native/persist/_index.yaml", "store", ["process", "ctx"])


def gate_runner(src):
    """Expire the drain timer or hold before the child starts when the probe asks."""
    runner = src / "placement/native/service/runner.lua"
    replace_once(runner, "selected = channel.select(cases)", '''selected = channel.select(drain_armed and not drain_expired and request.environment.PROBE_VALUE == "expire-pipe"
            and {drain_timer:case_receive()} or cases)''')
    replace_once(runner, "    local started, start_error = proc:start()", '''    if request.environment.PROBE_VALUE == "hold-retention" then
        local release = assert(process.listen("bee.test.native.release", {message = true}))
        assert(process.send(assert(recipient), "bee.test.native.held", {attempt_id = attempt_id}))
        local released = assert((release:receive()))
        assert(tostring(released:from()) == recipient, "retention gate sender")
        process.unlisten(release)
    end
    local started, start_error = proc:start()''')


def fixture_clock(src):
    """The gateway reads the time from a fixture instant a suite may pin."""
    shutil.copytree(TESTS / "fixtures/gateway_clock", src / "gateway_clock")
    gateway = src / "gateway/binding/gateway.lua"
    replace_once(gateway, 'local time = require("time")',
                 'local time = require("time")\nlocal fixture_clock = require("fixture_clock")')
    gateway.write_text(gateway.read_text().replace("time.now()", "fixture_clock.now()"))

    def import_clock(entries):
        entries["gateway"]["imports"]["fixture_clock"] = "bee.gateway:fixture_clock"
    update_entries(src / "gateway/binding/_index.yaml", import_clock)

    def read_instant(entries):
        policy = entries["store_policy"]["policy"]
        policy["actions"].append("registry.get")
        policy["resources"].append("bee.gateway:fixture_instant")
    update_entries(src / "gateway/security/_index.yaml", read_instant)


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
        entries["gateway_listener"]["addr"] = address
    update_entries(src / "gateway/api/_index.yaml", listen)

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
        local page = inspection.page(selected.entries, request.entry_offset, request.entry_limit, request.include_data)
        return {component = selected.component, version = selected.version, digest = selected.digest,
            entries = page.entries, requirements = configured, metadata = selected.metadata,
            next_offset = page.next_offset, eof = page.eof}, nil
    end''')
    text = index.read_text()
    anchor = text.index("- name: inspect\n")
    index.write_text(text[:anchor] + text[anchor:].replace("  imports:\n", "  imports:\n    fixture_catalog: bee.tests.gov:hub_fixture_catalog\n", 1))
    catalog = src / "hub/binding/catalog.lua"
    replace_once(catalog, '    local response, response_error', '''    if request.query == "fixture-unavailable" then return nil, "fixture catalog unavailable" end
    if request.query == nil or request.query == "progress" then
        return {items = {{component = "bee/progress", title = "Progress", description = "Task tracking",
            latest_version = "1.0.0", application = true}}, total = 1, page = request.page, page_size = M.PAGE_SIZE}, nil
    end
    local response, response_error''')
    replace_once(catalog, '    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})', '''    if request.component == "bee/progress" then
        return {component = request.component, latest_version = "1.0.0", title = "Progress", description = "Task tracking",
            readme = "", readme_error = "fixture README unavailable", versions = {{version = "1.0.0", yanked = false},
                {version = "9.0.0", yanked = false}}, total_versions = 2, page = request.page, page_size = M.MAX_VERSIONS}, nil
    end
    local module, module_error = hub.modules.get(request.component, {timeout = M.TIMEOUT_SECONDS})''')
    replace_once(src / "node/application_tests.lua", 'meta.type == "test"', 'meta.type == "app_test"')


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    environment["data"]["values"]["opencode"] = str(TESTS / "fixtures/harness/bin/opencode")
    target = TESTS / "lua/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


def owner_scheduling(src):
    replace_once(src / "credentials/service/worker.lua", 'funcs.call("bee.credentials.binding:configuration_effects")', 'nil, nil')
    replace_once(src / "credentials/service/worker.lua", 'return not backlog.pending()', 'return true')
    replace_once(src / "gov/service/activation_worker.lua", "pass = drain", "pass = function(): boolean return true end")
    replace_once(src / "gov/service/backlog.lua", "return pass.pending() or service.following_pending()", "return false")
    path = src / "threads/service/_index.yaml"
    document = yaml.safe_load(path.read_text())
    next(entry for entry in document["entries"] if entry["name"] == "service")["meta"]["pump"] = False
    path.write_text(yaml.safe_dump(document, sort_keys=False))
    path = src / "gateway/service/_index.yaml"
    document = yaml.safe_load(path.read_text())
    next(entry for entry in document["entries"] if entry["name"] == "external")["imports"]["effects"] = "bee.gateway.service:effects_fixture"
    next(entry for entry in document["entries"] if entry["name"] == "backlog")["source"] = "file://effects_disabled.lua"
    document["entries"].append({"name": "effects_fixture", "kind": "library.lua", "source": "file://effects_disabled.lua", "meta": {"type": "test_support"}})
    shutil.copy2(TESTS / "lua/gateway/effects_disabled.lua", src / "gateway/service/effects_disabled.lua")
    path.write_text(yaml.safe_dump(document, sort_keys=False))


def order_hive_readiness(src):
    replace_once(src / "hive/service/supervisor.lua",
                 '        if retry then cases[#cases + 1] = retry:case_receive() end',
                 '''        local owner = demanded["bee.gateway.external"]
        if owner and owner.state.phase ~= "absent"
            and process.registry.lookup("bee.test.hive.demand_ready", process.registry.LOCAL) then
            table.remove(cases, 2)
        end
        if retry then cases[#cases + 1] = retry:case_receive() end''')


def hold_test_runner_quiet(src):
    replace_once(src / "node/service/tests.lua",
                 "if #waiting == 0 then assert(demand.quiet(tests.NAME, generation)) else sweep() end",
                 """if #waiting == 0 then
                local controller = process.registry.lookup("bee.test.node.quiet")
                if controller then
                    local release = assert(process.listen("bee.test.node.quiet.release", {message = true}))
                    assert(process.send(tostring(controller), "bee.test.node.quiet", {}))
                    local message = assert((release:receive()))
                    assert(tostring(message:from()) == tostring(controller))
                    process.unlisten(release)
                end
                assert(demand.quiet(tests.NAME, generation))
            else sweep() end""")


def observe_preparer_cleanup(src):
    replace_once(src / "placement/native/service/workdir_preparers.lua",
                 "local after = assert(bounds.count(row.evidence_count))",
                 """local after = assert(bounds.count(row.evidence_count))
    local fixture = registry.get("bee.placement.native:preparer_fixture_config")
    if fixture and fixture.data and type(fixture.data.cleanup_observer) == "string" then
        assert(process.send(fixture.data.cleanup_observer, "bee.test.preparer.observed", {}))
    end""")
    replace_once(src / "placement/native/service/workdir_preparers.lua",
                 'local db, open_error = store.open()\n    if not db then return false, open_error end\n    local plans, plans_error = store.preparer_plans(db, attempt.attempt_id)',
                 '''local fixture = registry.get("bee.placement.native:preparer_fixture_config")
    if fixture and fixture.data and fixture.data.cleanup_crash_attempt == attempt.attempt_id and type(fixture.data.cleanup_crash) == "string" then
        local crash = assert(process.listen("bee.test.preparer.crash", {message = true}))
        assert(process.send(fixture.data.cleanup_crash, "bee.test.preparer.claimed", {}))
        assert((crash:receive()))
        error("fixture cleanup owner crashed")
    end
    local db, open_error = store.open()
    if not db then return false, open_error end
    local plans, plans_error = store.preparer_plans(db, attempt.attempt_id)''')


def hold_docker_cleanup(src):
    replace_once(src / "placement/docker/binding/methods.lua",
                 "function M.cleanup_loaded(loaded: Loaded): Reply",
                 """function M.cleanup_loaded(loaded: Loaded): Reply
    local controller = process.registry.lookup("bee.test.docker.cleanup")
    if controller then
        local release = assert(process.listen("bee.test.docker.cleanup.release", {message = true}))
        assert(process.send(tostring(controller), "bee.test.docker.cleanup", {attempt_id = loaded.attempt.attempt_id}))
        local message = assert((release:receive()))
        assert(tostring(message:from()) == tostring(controller))
        process.unlisten(release)
        local response = bounds.object(message:payload():data())
        if response and response.fail == true then return fail("UNAVAILABLE", "fixture cleanup refusal") end
    end""")


def advance_committed_transition(src):
    boundary = '''        return {ok = false, code = "STORAGE", message = "commit transition"}
    end'''
    replace_once(src / "placement/native/persist/store.lua", boundary, boundary + '''
    if update.evidence.kind == "test.transition_snapshot" then
        assert(M.transition(db, attempt_id, {cleanup = "complete",
            evidence = {kind = "test.transition_advanced", detail = "subsequent committed transition"}}).ok)
    end''')


def pause_effect_dispatch(src):
    path = src / "approvals/persist/dispatch.lua"
    replace_once(path, 'local sql = require("sql")', 'local sql = require("sql")\nlocal process = require("process")')
    replace_once(path, "function M.deliver(db: sql.DB, sender: Sender?): (integer?, string?)",
                 """function M.deliver(db: sql.DB, sender: Sender?): (integer?, string?)
    if not sender and process.registry.lookup("bee.test.effect_dispatch", process.registry.LOCAL) then return 0, nil end""")
    add_modules(src / "approvals/persist/_index.yaml", "dispatch", ["process"])


def observe_effect_delivery(src):
    replace_once(src / "process/demand_owner.lua",
                 "function M.receive(owners: Owners, from: string, raw: unknown)",
                 """function M.receive(owners: Owners, from: string, raw: unknown)
    local controller = process.registry.lookup("bee.test.effect_delivery", process.registry.LOCAL)
    if controller and tostring(controller) == from and type(raw) == "table" and raw.action == "bee.test.boot_backlog" then
        M.recover(owners, nil)
        return
    end""")
    replace_once(src / "process/demand_owner.lua",
                 "        for _, request in ipairs(requests) do",
                 """        local observer = process.registry.lookup("bee.test.effect_delivery")
        if observer then
            process.send(tostring(observer), "bee.test.effect_delivery", {
                name = owner.name, pid = pid, generation = owner.state.generation, requests = requests})
        end
        for _, request in ipairs(requests) do""")


def observe_boot_recovery(src):
    shutil.copy2(TESTS / "lua/gov/recovery_trace.lua", src / "gov/service/recovery_trace.lua")
    replace_once(src / "gov/service/recovery.lua", 'local logger = require("logger")',
                 'local trace = require("trace")\nlocal logger = require("logger")')
    replace_once(src / "gov/service/recovery.lua", "local function main()", "local function main()\n    trace.record()")
    path = src / "gov/service/_index.yaml"
    document = yaml.safe_load(path.read_text())
    next(entry for entry in document["entries"] if entry["name"] == "recovery")["imports"]["trace"] = "bee.gov.service:recovery_trace"
    document["entries"].append({"name": "recovery_trace", "kind": "library.lua", "source": "file://recovery_trace.lua", "modules": ["sql"], "meta": {"type": "test_support"}})
    path.write_text(yaml.safe_dump(document, sort_keys=False))


def main():
    shutil.rmtree(COMPOSITION, ignore_errors=True)
    src = COMPOSITION / "src"
    shutil.copytree(ROOT / "src", src)
    # The composition is a module root like the repository: its manifest
    # beside src, so module-relative directories resolve as they do in a pack.
    shutil.copy(ROOT / "wippy.yaml", COMPOSITION / "wippy.yaml")
    owner_scheduling(src)
    hold_test_runner_quiet(src)
    order_hive_readiness(src)
    hold_docker_cleanup(src)
    advance_committed_transition(src)
    observe_preparer_cleanup(src)
    pause_effect_dispatch(src)
    observe_effect_delivery(src)
    observe_boot_recovery(src)
    observe_carrier(src)
    hold_attempt_snapshot(src)
    gate_runner(src)
    fixture_clock(src)
    shutil.copytree(TESTS / "fixtures/memory", src / "test_memory")
    yield_session_defaults(src)
    managed_gateway(src)
    runner_fixture_type(src)
    shutil.copy2(ROOT / "src/placement/native/service/materialization.lua",
                 TESTS / "lua/placement_publication/materialization.lua")
    shutil.copy2(ROOT / "src/placement/docker/service/image_owner.lua",
                 TESTS / "lua/placement_owner/image_owner.lua")
    shutil.copy2(ROOT / "src/gov/service/activation_worker.lua",
                 TESTS / "lua/gov/activation_worker.lua")
    shutil.copy2(ROOT / "src/process/demand_owner.lua",
                 TESTS / "lua/process/demand_owner.lua")
    host_environment()


if __name__ == "__main__":
    sys.exit(main())

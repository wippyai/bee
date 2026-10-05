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
fixture as the installed claude executable, and the gateway listens on one
selected loopback port the suites open explicitly.
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


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    target = TESTS / "lua/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


def main():
    shutil.rmtree(COMPOSITION, ignore_errors=True)
    src = COMPOSITION / "src"
    shutil.copytree(ROOT / "src", src)
    # The composition is a module root like the repository: its manifest
    # beside src, so module-relative directories resolve as they do in a pack.
    shutil.copy(ROOT / "wippy.yaml", COMPOSITION / "wippy.yaml")
    observe_carrier(src)
    hold_attempt_snapshot(src)
    gate_runner(src)
    fixture_clock(src)
    yield_session_defaults(src)
    managed_gateway(src)
    shutil.copy2(ROOT / "src/placement/native/service/materialization.lua",
                 TESTS / "lua/placement_publication/materialization.lua")
    host_environment()


if __name__ == "__main__":
    sys.exit(main())

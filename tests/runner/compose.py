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


def host_environment():
    """The unit host facts, with the Claude fixture as the installed claude."""
    document = yaml.safe_load((TESTS / "fixtures/harness/host.yaml").read_text())
    environment = next(entry for entry in document["entries"] if entry["name"] == "environment")
    environment["data"]["values"]["claude"] = str(TESTS / "fixtures/harness/bin/claude")
    environment["data"]["values"]["opencode"] = str(TESTS / "fixtures/harness/bin/opencode")
    target = COMPOSITION / "src/harness/host/_index.yaml"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(yaml.safe_dump(document, sort_keys=False))


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
    observe_sync_idle(src)
    shutil.copytree(TESTS / "fixtures/memory", src / "test_memory")
    shutil.copytree(TESTS / "fixtures/persist/retained", src / "test_retained")
    managed_gateway(src)
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

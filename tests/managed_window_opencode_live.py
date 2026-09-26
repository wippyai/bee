"""Live smoke: a real `opencode` window through the managed broker, no login.

The production OpenCode driver binding, window profile, admission, carrier,
placement and broker PTY path are exercised end to end with the actual
executable. The window is opened, its startup output is observed and it is
closed; no prompt is submitted and no sign-in is performed. The real
executable reads its own inherited OpenCode home, exactly as `bee opencode`
does; Bee only checks that the declared login evidence exists.

Required environment: BEE_RUNTIME (the combined runtime binary) and
BEE_OPENCODE_BIN (the real opencode executable).
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import workspace

ROOT = Path(__file__).resolve().parents[1]


def main():
    selected = os.environ.get("BEE_OPENCODE_BIN", "")
    if not selected or not os.path.isfile(selected):
        sys.exit(f"BEE_OPENCODE_BIN must name the real opencode executable; got {selected!r}")
    version = subprocess.run([selected, "--version"], capture_output=True, text=True, timeout=60)
    print(f"Actual OpenCode under test: {(version.stdout + version.stderr).strip()[:80]}", flush=True)
    with workspace.fixture_workspace(unit_tests=False) as folder:
        tests = folder / "src/tests"
        shutil.copytree(ROOT / "tests/fixtures/managed_window_opencode", tests / "managed_window_opencode")
        path = tests / "managed_window_opencode/_index.yaml"
        import yaml
        document = yaml.safe_load(path.read_text())
        policy = next(e for e in document["entries"] if e["name"] == "policy")["data"]
        policy["executables"] = {"opencode": selected}
        path.write_text(yaml.safe_dump(document, sort_keys=False))
        main_lua = tests / "managed_window_opencode/main.lua"
        main_lua.write_text(REAL_SMOKE)
        # The real executable reads its own inherited OpenCode home. Point
        # HOME at a fixture home carrying the declared login evidence so the
        # smoke exercises the startup path without any credential: the empty
        # evidence file's existence is all the runtime inspects, and the real
        # executable never signs in here.
        home = folder / "provider-home"
        evidence = home / ".local/share/opencode/auth.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("")
        environment = workspace.database_environment(folder, HOME=str(home))
        for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY"):
            environment.pop(key, None)
        subprocess.run([str(workspace.RUNTIME), "lint", "--ns", "bee.managed.opencode.fixture"],
                       cwd=folder, env=environment, check=True, timeout=90)
        run = subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal"],
                             cwd=folder, capture_output=True, text=True,
                             timeout=int(os.environ.get("BEE_OPENCODE_WINDOW_TIMEOUT", "180")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        if run.returncode != 0:
            print(out[-4000:])
            sys.exit(run.returncode)
        print(out.strip().splitlines()[-6] if out.strip() else "")
    print("Live managed OpenCode window: real executable opened through the broker PTY and closed; "
          "no prompt submitted and no login performed")


REAL_SMOKE = '''-- MIT. Live smoke: open a real opencode window through the broker and close
-- it. No prompt is submitted and no login is performed; the executable reads
-- its own inherited home, as the production bee opencode command does.
local process = require("process")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local appearance = require("appearance")
local M = {}
local WORKSPACE = string.rep("a", 32)
local function plain(value: string): string
    return (value:gsub("\\27%[[0-9;]*m", ""))
end
local function reply(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("missing reply") end
    return value :: {[string]: unknown}
end
local function call(target: string, value: unknown): {[string]: unknown}
    local raw, call_error = funcs.call(target, value)
    if call_error then error(target .. ": " .. tostring(call_error)) end
    local result = reply(raw)
    if result.ok ~= true then
        local fault = type(result.error) == "table" and result.error :: {[string]: unknown} or {}
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return result
end
local channel = require("channel")
local function receive_reply(replies: any, request_id: string, operation: string, budget: string): {[string]: unknown}
    local deadline = time.after(budget or "20s")
    while true do
        local received = channel.select({replies:case_receive(), deadline:case_receive()})
        assert(received.ok and received.channel == replies, "no " .. operation .. " reply for " .. request_id)
        local message = received.value
        local data = message:payload():data()
        if type(data) == "table" and data.request_id == request_id and data.op == operation then
            return data :: {[string]: unknown}
        end
    end
    return {}
end
function M.run()
    local thread = "managed_opencode_live_thread"
    call("bee.threads.service:create", {thread_id = thread, idempotency_key = thread .. "-create", title = "Open OpenCode window"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local broker_policy = security.policy("bee.security.desktop:broker_policy")
    if not broker_policy then error("broker policy") end
    local boundary = security.policy("bee.security:core_spawn_boundary")
    if not boundary then error("spawn boundary") end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive():from() == broker)
    local request = assert(json.encode({request_id = "opencode-live-request", definition_ref = "bee.managed.opencode.fixture:definition",
        brief = "", thread_id = thread}))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-live-open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", thread_id = thread, arguments = {request}}))
    local opened = receive_reply(replies, "opencode-live-open", "open", "60s")
    assert(opened.error_code == "", "managed OpenCode window did not become ready: " .. tostring(opened.error))
    local id = tostring(opened.id)
    local instance_id = tostring(opened.instance_id)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-live-bind", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local attached = receive_reply(replies, "opencode-live-bind", "attached", "30s")
    assert(attached.error_code == "")
    local view = assert(tty.attach(tostring(attached.mount)))
    assert(view:send({type = "resize", width = 120, height = 30}))
    local drew = false
    for _ = 1, 200 do
        local frame = plain(table.concat(assert(view:snapshot()).rows))
        if #(frame:gsub("%s", "")) > 0 then drew = true; break end
        time.sleep("25ms")
    end
    assert(drew, "real opencode did not draw in the broker PTY")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-live-close", op = "close", workspace_id = WORKSPACE, id = id}))
    local closed = receive_reply(replies, "opencode-live-close", "close", "20s")
    assert(closed.error_code == "", "managed OpenCode close failed")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-live-bind2", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
    view:close()
    local records = call("bee.threads.service:read_after", {thread_id = thread, cursor = 0, limit = 32})
    local kinds: {[string]: boolean} = {}
    local value = records.value :: {[string]: unknown}
    for _, item in ipairs(value.records :: {{[string]: unknown}}) do kinds[tostring(item.kind)] = true end
    assert(kinds["attempt.prepared"] and kinds["attempt.started"] and kinds["receipt"], "live OpenCode attempt lifecycle was incomplete")
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies)
end
return M
'''


if __name__ == "__main__":
    main()

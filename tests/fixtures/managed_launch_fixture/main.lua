-- MIT. A managed agent reaches a real native terminal with no provider
-- account: the launch definition, admission, carrier (planning) and
-- placement path are the same ones a real Claude Code window uses; only
-- the executable at the far end is the protocol fixture, replaying a
-- captured stream-json-2 transcript. The broker really spawns a process,
-- the process really owns a PTY, and the bytes on screen are the ones
-- that process actually wrote.
local test = require("test")
local process = require("process")
local registry = require("registry")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local appearance = require("appearance")

local WORKSPACE = string.rep("a", 32)
local MARKER = "claude-fable-5-1"

local function plain(value: string): string
    return (value:gsub("\27%[[0-9;]*m", ""))
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

local function receive_reply(replies: any, request_id: string, operation: string): {[string]: unknown}
    while true do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if type(data) == "table" and data.request_id == request_id and data.op == operation then
            return data :: {[string]: unknown}
        end
    end
    return {}
end

local function define_tests()
    test.describe("Fixture-provider managed terminal", function()
        test.it("opens a real native terminal for the fixture provider and leaves launch evidence on the thread", function()
            local thread = "fixture_terminal_thread"
            call("bee.threads.service:create", {thread_id = thread, idempotency_key = thread .. "-create", title = "Open fixture provider window"})
            local owner = tostring(process.pid())
            local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
            local replies = assert(process.listen("bee.app.reply", {message = true}))
            local broker_policy, broker_error = security.policy("bee:broker_policy")
            if not broker_policy then error(tostring(broker_error)) end
            local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
            if not boundary then error(tostring(boundary_error)) end
            local scope = security.new_scope({broker_policy, boundary})
            local broker = tostring(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
                :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults()))
            assert(catalogs:receive():from() == broker)
            local request = assert(json.encode({request_id = "fixture-request", definition_ref = "bee.fixture_terminal_launch:definition", brief = "", thread_id = thread}))
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "fixture-open", op = "open", workspace_id = WORKSPACE,
                definition_id = "bee.harness.window:app", arguments = {request}}))
            local opened = receive_reply(replies, "fixture-open", "open")
            assert(opened.error_code == "", "fixture provider window did not become ready: " .. tostring(opened.error))
            local id = tostring(opened.id)
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "fixture-bind", op = "bind", workspace_id = WORKSPACE,
                id = opened.id, instance_id = opened.instance_id, recipient = owner}))
            local attached = receive_reply(replies, "fixture-bind", "attached")
            assert(attached.error_code == "")
            local view = assert(tty.attach(tostring(attached.mount)))
            assert(view:send({type = "resize", width = 100, height = 30}))
            local saw = false
            for _ = 1, 400 do
                local frame = assert(view:snapshot())
                if plain(table.concat(frame.rows)):find(MARKER, 1, true) then saw = true; break end
                time.sleep("25ms")
            end
            assert(saw, "fixture provider startup marker absent from broker PTY: " .. table.concat(view:snapshot().rows, "\n"))
            view:close()
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "fixture-close", op = "close", workspace_id = WORKSPACE, id = id}))
            local closed = receive_reply(replies, "fixture-close", "close")
            assert(closed.error_code == "", "fixture provider window close failed")
            local records = call("bee.threads.service:read_after", {thread_id = thread, cursor = 0, limit = 32})
            local kinds: {[string]: boolean} = {}
            local value = records.value :: {[string]: unknown}
            for _, item in ipairs(value.records :: {{[string]: unknown}}) do kinds[tostring(item.kind)] = true end
            assert(kinds["action.admitted"], "the launch definition was not admitted onto the thread")
            assert(kinds["attempt.prepared"] and kinds["attempt.started"], "placement did not record a real attempt for the fixture provider")
            assert(kinds["receipt"], "the native window did not settle a receipt for the fixture provider")
            process.terminate(broker)
            process.unlisten(catalogs); process.unlisten(replies)
        end)
    end)
end

return test.run_cases(define_tests)

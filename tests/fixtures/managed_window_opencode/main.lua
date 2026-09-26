-- MIT. A managed OpenCode window reaches a real native terminal through the
-- production driver binding and window profile; only the executable is the
-- fixture. The broker really spawns a process, the process really owns a PTY,
-- and the frame we see is the one the process wrote. No prompt is submitted
-- and no login is performed.
local process = require("process")
local registry = require("registry")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local appearance = require("appearance")

local M = {}
local WORKSPACE = string.rep("a", 32)

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

local function run()
    local expected = assert(registry.get("bee.managed.opencode.fixture:expectation"))
    local data = expected.data :: {[string]: unknown}
    local marker = tostring(data.marker)
    local thread = "managed_opencode_thread"
    call("bee.threads.service:create", {thread_id = thread, idempotency_key = thread .. "-create", title = "Open OpenCode window"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local broker_policy, broker_error = security.policy("bee.security.desktop:broker_policy")
    if not broker_policy then error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee.security:core_spawn_boundary")
    if not boundary then error(tostring(boundary_error)) end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive():from() == broker)
    local request = assert(json.encode({request_id = "opencode-request", definition_ref = "bee.managed.opencode.fixture:definition",
        brief = tostring(data.brief), thread_id = thread}))
    -- A direct open names the thread on the broker request so the broker
    -- admits the host-issued application principal it starts.
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", thread_id = thread, arguments = {request}}))
    local opened = receive_reply(replies, "opencode-open", "open")
    assert(opened.error_code == "", "managed OpenCode app did not become ready: " .. tostring(opened.error))
    local id = tostring(opened.id)
    local instance_id = tostring(opened.instance_id)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-bind-one", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local attached = receive_reply(replies, "opencode-bind-one", "attached")
    assert(attached.error_code == "")
    local view = assert(tty.attach(tostring(attached.mount)))
    assert(view:send({type = "resize", width = 100, height = 30}))
    -- The window profile inherits the host user home, and the fixture home
    -- carries the declared login evidence, so the provider starts directly.
    -- The evidence file is never read; only its existence is checked.
    local saw = false
    for _ = 1, 400 do
        local frame = plain(table.concat(assert(view:snapshot()).rows))
        if frame:find(marker, 1, true) then saw = true; break end
        time.sleep("25ms")
    end
    assert(saw, "OpenCode startup marker absent from broker PTY: " .. table.concat(view:snapshot().rows, "\n"))
    assert(view:send({type = "paste", text = "managed-input"}))
    local echoed = false
    for _ = 1, 100 do
        if plain(table.concat(view:snapshot().rows)):find("managed-input", 1, true) then echoed = true; break end
        time.sleep("25ms")
    end
    assert(echoed, "OpenCode startup UI did not receive input")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-detach", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
    local detached = receive_reply(replies, "opencode-detach", "bind")
    assert(detached.error_code == "")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-bind-two", op = "bind", workspace_id = WORKSPACE,
        id = id, instance_id = instance_id, recipient = owner}))
    local rebound = receive_reply(replies, "opencode-bind-two", "attached")
    assert(rebound.error_code == "")
    local next_view = assert(tty.attach(tostring(rebound.mount)))
    local rebound_frame = plain(table.concat(next_view:snapshot().rows))
    assert(rebound_frame:find(marker, 1, true), "OpenCode detach lost the provider UI")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "opencode-close", op = "close", workspace_id = WORKSPACE, id = id}))
    local closed = receive_reply(replies, "opencode-close", "close")
    assert(closed.error_code == "", "managed OpenCode close failed")
    local records = call("bee.threads.service:read_after", {thread_id = thread, cursor = 0, limit = 32})
    local kinds: {[string]: boolean} = {}
    local value = records.value :: {[string]: unknown}
    local receipts = 0
    for _, item in ipairs(value.records :: {{[string]: unknown}}) do
        kinds[tostring(item.kind)] = true
        if item.kind == "receipt" then
            receipts = receipts + 1
            local body = reply(item.body)
            assert(body.scope == "attempt" and body.outcome == "cancelled", "receipt must distinguish terminal completion from explicit cancellation")
            local fault = reply(body.error)
            assert(fault.code == "native_window_closed", "receipt must identify its evidence")
        end
    end
    assert(receipts == 1, "OpenCode close must settle exactly one attempt receipt")
    assert(not kinds["turn.request"] and not kinds["turn.end"], "OpenCode PTY lifecycle must not invent logical turns")
    assert(kinds["attempt.prepared"] and kinds["attempt.started"] and kinds["receipt"], "OpenCode managed attempt lifecycle was incomplete")
    next_view:close(); view:close()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies)
end

M.run = run
return M

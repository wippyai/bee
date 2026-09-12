-- Fixture-only broker acceptance for the private managed-window application.
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local appearance = require("appearance")
local admission = require("admission")

local M = {}
local WORKSPACE = string.rep("a", 32)

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

local function run(natural: boolean)
    local THREAD = natural and "managed_window_natural" or "managed_window_thread"
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "managed-window-create", title = "Managed window fixture"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local broker_policy, broker_error = security.policy("bee:broker_policy")
    if not broker_policy then error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
    if not boundary then error(tostring(boundary_error)) end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive():from() == broker)
    local plan, refused = admission.resolve("bee.managed_window_fixture:definition", "window")
    if not plan then error("resolve window plan: " .. tostring(refused and refused.error and refused.error.message)) end
    local request = assert(json.encode({request_id = natural and "managed-window-natural-request" or "managed-window-request", definition_ref = "bee.managed_window_fixture:definition", brief = "managed window",
        thread_id = THREAD, expected_plan_digest = plan.plan_digest}))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", arguments = {request}}))
    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = assert(replies:receive())
        if tostring(message:from()) == broker then
            local data = message:payload():data()
            if type(data) == "table" and data.request_id == "open" and data.op == "open" then opened = data :: {[string]: unknown} end
        end
    end
    assert(opened.error_code == "", "managed app did not become ready: " .. tostring(opened.error))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind-one", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local mounted = ""
    while mounted == "" do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-one" and data.op == "attached" then
            assert(data.error_code == "")
            mounted = tostring(data.mount)
        end
    end
    local view = assert(tty.attach(mounted))
    assert(view:send({type = "resize", width = 30, height = 10}))
    assert(view:send({type = "paste", text = "hello"}))
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
    local saw = false
    for _ = 1, 100 do
        local frame = assert(view:snapshot())
        if table.concat(frame.rows):find("MANAGED:hello", 1, true) then saw = true; break end
        time.sleep("25ms")
    end
    assert(saw, "broker-mounted PTY did not receive input")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "detach", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
    local detached = false
    while not detached do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "detach" and data.op == "bind" then detached = data.error_code == "" end
    end
    assert(detached)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind-two", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local rebound = ""
    while rebound == "" do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-two" and data.op == "attached" then rebound = tostring(data.mount) end
    end
    local next_view = assert(tty.attach(rebound))
    assert(table.concat(next_view:snapshot().rows):find("MANAGED:hello", 1, true), "detach restarted the managed child")
    if not natural then
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
        local closed = false
        while not closed do
            local message = assert(replies:receive())
            local data = message:payload():data()
            if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "close" and data.op == "close" then closed = data.error_code == "" end
        end
        assert(closed, "managed app close failed")
    else
        local settled = false
        for _ = 1, 160 do
            local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32})
            local page_value = reply(page.value)
            for _, record in ipairs(page_value.records :: {{[string]: unknown}}) do
                if record.kind == "receipt" then settled = true end
            end
            if settled then break end
            time.sleep("50ms")
        end
        assert(settled, "natural PTY completion never settled an attempt")
    end
    local records = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32})
    local kinds: {[string]: boolean} = {}
    local value = records.value :: {[string]: unknown}
    local receipts = 0
    for _, item in ipairs(value.records :: {{[string]: unknown}}) do
        kinds[tostring(item.kind)] = true
        if item.kind == "receipt" then
            receipts = receipts + 1
            local body = reply(item.body)
            assert(body.scope == "attempt" and body.outcome == (natural and "uncertain" or "cancelled"), "receipt must distinguish terminal completion from explicit cancellation")
            local fault = reply(body.error)
            assert(fault.code == (natural and "native_window_unobserved" or "native_window_closed"), "receipt must identify its evidence")
        end
    end
    assert(receipts == 1, "close must settle exactly one attempt receipt")
    assert(not kinds["turn.request"] and not kinds["turn.end"], "PTY lifecycle must not invent logical turns")
    local stale_input = next_view:send({type = "paste", text = "must not reach a closed app"})
    assert(not stale_input, "closed application retained its input grant")
    assert(kinds["attempt.prepared"] and kinds["attempt.started"] and kinds["receipt"], "managed attempt lifecycle was incomplete")
    next_view:close(); view:close()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies)
end

M.run = function() run(false) end
M.natural = function() run(true) end
return M

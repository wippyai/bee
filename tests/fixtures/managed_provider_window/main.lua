-- Actual provider startup through the broker; no prompt or authentication.
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

local function run(provider: string, definition: string, marker: string, title: string, thread: string)
    call("bee.threads.service:create", {thread_id = thread, idempotency_key = thread .. "-create", title = title})
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
    local request = assert(json.encode({request_id = provider .. "-request", definition_ref = definition, brief = "",
        thread_id = thread}))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = provider .. "-open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", arguments = {request}}))
    local opened = receive_reply(replies, provider .. "-open", "open")
    assert(opened.error_code == "", "managed " .. provider .. " app did not become ready: " .. tostring(opened.error))
    local id = tostring(opened.id)
    local instance_id = tostring(opened.instance_id)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = provider .. "-bind-one", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local attached = receive_reply(replies, provider .. "-bind-one", "attached")
    assert(attached.error_code == "")
    local view = assert(tty.attach(tostring(attached.mount)))
    assert(view:send({type = "resize", width = 100, height = 30}))
    local saw = false
    for _ = 1, 400 do
        local frame = assert(view:snapshot())
        if plain(table.concat(frame.rows)):find(marker, 1, true) then saw = true; break end
        time.sleep("25ms")
    end
    assert(saw, provider .. " startup marker absent from broker PTY: " .. table.concat(view:snapshot().rows, "\n"))
    local before = plain(table.concat(view:snapshot().rows))
    local selected: number? = nil
    if provider == "claude" then
        local candidate = tonumber(before:match("❯%s+(%d+)%."))
        if not candidate then error("Claude startup UI is not visible") end
        selected = candidate
        assert(view:send({type = "key", key = "", key_type = "down", action = "press"}))
        local changed = false
        for _ = 1, 100 do
            if tonumber(plain(table.concat(view:snapshot().rows)):match("❯%s+(%d+)%.")) == selected + 1 then changed = true; break end
            time.sleep("25ms")
        end
        assert(changed, "Claude startup UI did not react to keyboard input")
    else
        assert(view:send({type = "paste", text = "managed-input"}))
        local changed = false
        for _ = 1, 100 do
            if plain(table.concat(view:snapshot().rows)):find("managed-input", 1, true) then changed = true; break end
            time.sleep("25ms")
        end
        assert(changed, "Codex startup UI did not react to keyboard input")
    end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = provider .. "-detach", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
    local detached = receive_reply(replies, provider .. "-detach", "bind")
    assert(detached.error_code == "")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = provider .. "-bind-two", op = "bind", workspace_id = WORKSPACE,
        id = id, instance_id = instance_id, recipient = owner}))
    local rebound = receive_reply(replies, provider .. "-bind-two", "attached")
    assert(rebound.error_code == "")
    local next_view = assert(tty.attach(tostring(rebound.mount)))
    local rebound_frame = plain(table.concat(next_view:snapshot().rows))
    assert(rebound_frame:find(marker, 1, true), provider .. " detach lost the provider UI")
    if provider == "claude" then
        assert(tonumber(rebound_frame:match("❯%s+(%d+)%s*%.")) == (selected :: number) + 1, "Claude detach reset the provider selection")
    else
        assert(rebound_frame:find("managed-input", 1, true), "Codex detach lost typed input")
    end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = provider .. "-close", op = "close", workspace_id = WORKSPACE, id = id}))
    local closed = receive_reply(replies, provider .. "-close", "close")
    assert(closed.error_code == "", "managed " .. provider .. " close failed")
    local records = call("bee.threads.service:read_after", {thread_id = thread, cursor = 0, limit = 32})
    local kinds: {[string]: boolean} = {}
    local value = records.value :: {[string]: unknown}
    local receipts = 0
    for _, item in ipairs(value.records :: {{[string]: unknown}}) do
        kinds[tostring(item.kind)] = true
        if item.kind == "action.admitted" then
            local admitted = reply(item.body)
            local input = reply(admitted.input)
            assert(input.text == title, "empty prompt must describe opening the " .. provider .. " UI: " .. tostring(input.text))
        end
        if item.kind == "receipt" then
            receipts = receipts + 1
            local body = reply(item.body)
            assert(body.scope == "attempt" and body.outcome == "cancelled", "receipt must distinguish terminal completion from explicit cancellation")
            local fault = reply(body.error)
            assert(fault.code == "native_window_closed", "receipt must identify its evidence")
        end
    end
    assert(receipts == 1, provider .. " close must settle exactly one attempt receipt")
    assert(not kinds["turn.request"] and not kinds["turn.end"], provider .. " PTY lifecycle must not invent logical turns")
    local stale_input = next_view:send({type = "paste", text = "must not reach a closed app"})
    assert(not stale_input, provider .. " closed application retained its input grant")
    assert(kinds["attempt.prepared"] and kinds["attempt.started"] and kinds["receipt"], provider .. " managed attempt lifecycle was incomplete")
    next_view:close(); view:close()
    process.terminate(broker)
    process.unlisten(catalogs); process.unlisten(replies)
end

local function run_all()
    local expected = assert(registry.get("bee.managed.provider.fixture:expectation"))
    local data = expected.data :: {[string]: unknown}
    run("claude", "bee.managed.provider.fixture:definition_claude", tostring(data.claude_marker), "Open Claude Code window", "managed_claude_thread")
    run("codex", "bee.managed.provider.fixture:definition_codex", tostring(data.codex_marker), "Open Codex CLI window", "managed_codex_thread")
end

M.run = run_all
return M

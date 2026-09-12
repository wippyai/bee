-- Real native-window hook acceptance fixture.
local process = require("process")
local channel = require("channel")
local time = require("time")
local security = require("security")
local tty = require("tty")
local funcs = require("funcs")
local json = require("json")
local appearance = require("appearance")
local registry = require("registry")
local admission = require("admission")

local M = {}
local WORKSPACE = string.rep("b", 32)
local THREAD = "window_hooks_thread"

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

local function endpoint(): string
    local entry, err = registry.get("bee:gateway_endpoint")
    assert(not err and entry and type(entry.data) == "table", "gateway endpoint")
    local address = (entry.data :: {[string]: unknown}).address
    assert(type(address) == "string" and (address :: string):find("^127%.0%.0%.1:%d+$"), "gateway endpoint address")
    return address :: string
end

local function execute()
    -- 1. Open gateway listener under configured loopback endpoint
    local address = endpoint()
    local opened_gateway = call("bee.gateway:open", {address = address})
    assert(opened_gateway.value ~= nil, "failed to open gateway listener")

    -- 2. Create the target thread
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "window-hooks-create", title = "Window hooks fixture"})

    -- 3. Spawn real native application broker
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

    -- 4. Resolve plan and open bee.harness.window:app
    local plan, refused = admission.resolve("bee.window_hooks_fixture:definition", "window")
    if not plan then error("resolve window plan: " .. tostring(refused and refused.error and refused.error.message)) end

    local request = assert(json.encode({
        request_id = "window-hooks-req",
        definition_ref = "bee.window_hooks_fixture:definition",
        brief = "window hooks acceptance",
        thread_id = THREAD,
        expected_plan_digest = plan.plan_digest,
    }))

    assert(process.send(broker, "bee.app.request", {
        version = 1,
        request_id = "open",
        op = "open",
        workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app",
        arguments = {request},
    }))

    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = assert(replies:receive())
        if tostring(message:from()) == broker then
            local data = message:payload():data()
            if type(data) == "table" and data.request_id == "open" and data.op == "open" then
                opened = data :: {[string]: unknown}
            end
        end
    end
    if opened.error_code ~= "" then
        local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0})
        local records = page.value and (page.value :: {[string]: unknown}).records or {}
        local last_receipt = ""
        for _, rec in ipairs(records :: {unknown}) do
            local item = rec :: {[string]: unknown}
            if item.kind == "receipt" and type(item.body) == "table" then
                local body = item.body :: {[string]: unknown}
                if type(body.error) == "table" then
                    last_receipt = tostring((body.error :: {[string]: unknown}).message)
                end
            end
        end
        error("managed window app failed (" .. tostring(opened.error_code) .. "): " .. tostring(opened.error) .. (last_receipt ~= "" and (": " .. last_receipt) or ""))
    end
    assert(opened.error_code == "", "managed window app did not become ready: " .. tostring(opened.error))

    -- 5. Bind PTY viewport
    assert(process.send(broker, "bee.app.request", {
        version = 1,
        request_id = "bind-one",
        op = "bind",
        workspace_id = WORKSPACE,
        id = opened.id,
        instance_id = opened.instance_id,
        recipient = owner,
    }))

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
    assert(view:send({type = "resize", width = 80, height = 24}))

    -- 6. Verify child submitted hook and gateway returned 202 Accepted
    local hook_submitted = false
    for _ = 1, 160 do
        local frame, frame_error = view:snapshot()
        if frame and table.concat(frame.rows):find("HOOK_HTTP_CODE:202", 1, true) then
            hook_submitted = true
            break
        end
        time.sleep("50ms")
    end
    assert(hook_submitted, "actual hook was not accepted by real gateway (expected HOOK_HTTP_CODE:202)")

    -- 7. Verify terminal input is functional
    assert(view:send({type = "paste", text = "first-pty-check"}))
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
    local pty_functional_before = false
    for _ = 1, 100 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows):find("HOOK_CHILD_INPUT:first-pty-check", 1, true) then
            pty_functional_before = true
            break
        end
        time.sleep("25ms")
    end
    assert(pty_functional_before, "terminal input is not functional before hook commit")

    -- 8. Verify hook committed by window as thread extension without turn
    local hook_committed = false
    local committed_event_id: string? = nil
    local committed_binding_id: string? = nil
    local committed_record: {[string]: unknown}? = nil

    for _ = 1, 200 do
        local records = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64})
        local value = reply(records.value)
        for _, item in ipairs(value.records :: {{[string]: unknown}}) do
            if item.kind == "observation" and type(item.body) == "table" then
                local body = item.body :: {[string]: unknown}
                local event_key = tostring(body.event_key or "")
                if event_key:find("^hook:") then
                    hook_committed = true
                    committed_record = item
                    if type(body.data) == "table" then
                        local data = body.data :: {[string]: unknown}
                        if data.payload_json then
                            local decoded = json.decode(tostring(data.payload_json))
                            if type(decoded) == "table" then
                                local payload_obj = decoded :: {[string]: unknown}
                                committed_event_id = tostring(payload_obj.event_id or "")
                                committed_binding_id = tostring(payload_obj.binding_id or "")
                            end
                        end
                    end
                    break
                end
            end
        end
        if hook_committed then break end
        time.sleep("50ms")
    end
    assert(hook_committed, "hook was not committed by window to thread")
    assert(committed_record ~= nil, "missing committed hook observation record")
    assert(committed_record.turn_id == nil, "committed hook must not have a turn_id (extension without turn)")

    -- 9. Verify hook acknowledged once by real gateway
    if committed_binding_id and committed_binding_id ~= "" then
        local queue_res = call("bee.gateway:hook_queue", {binding_id = committed_binding_id})
        local queue_val = reply(queue_res.value)
        local found_hook: {[string]: unknown}? = nil
        for _, h in ipairs(queue_val.hooks :: {{[string]: unknown}}) do
            if committed_event_id and h.event_id == committed_event_id then
                found_hook = h
                break
            end
        end
        assert(found_hook ~= nil, "committed hook not found in gateway queue")
        assert(found_hook.status == "committed", "hook status in gateway must be committed (acknowledged once)")
    end

    -- 10. Verify terminal input stays functional after hook commit
    assert(view:send({type = "paste", text = "second-pty-check"}))
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
    local pty_functional_after = false
    for _ = 1, 100 do
        local frame = view:snapshot()
        if frame and table.concat(frame.rows):find("HOOK_CHILD_INPUT:second-pty-check", 1, true) then
            pty_functional_after = true
            break
        end
        time.sleep("25ms")
    end
    assert(pty_functional_after, "terminal input did not remain functional after hook commit")

    -- 11. Close application and verify clean shutdown
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
    local closed = false
    while not closed do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "close" and data.op == "close" then
            closed = data.error_code == ""
        end
    end
    assert(closed, "managed window close failed")

    -- 12. Verify single attempt receipt with outcome cancelled
    local settled = false
    local receipts = 0
    for _ = 1, 100 do
        local records = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64})
        local value = reply(records.value)
        for _, item in ipairs(value.records :: {{[string]: unknown}}) do
            if item.kind == "receipt" then
                receipts = receipts + 1
                local body = reply(item.body)
                assert(body.scope == "attempt" and body.outcome == "cancelled", "expected cancelled receipt")
                settled = true
            end
        end
        if settled then break end
        time.sleep("50ms")
    end
    assert(receipts == 1, "expected exactly one cancelled receipt")

    -- 13. Teardown
    view:close()
    process.terminate(broker)
    process.unlisten(catalogs)
    process.unlisten(replies)
    print("BEE_WINDOW_HOOKS_ACCEPTANCE: OK")
end

M.main = execute
M.run = execute

return M

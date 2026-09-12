-- Fixture-only broker acceptance for the private managed-window application.
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
local homes = require("homes")
local fs = require("fs")

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

local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("fixture update: " .. tostring(err)) end
end
local function changed(entry: {[string]: unknown}): {[string]: unknown}
    local result: {[string]: unknown} = {}
    for key, value in pairs(entry) do result[key] = value end
    local data: {[string]: unknown} = {}
    for key, value in pairs(entry.data :: {[string]: unknown}) do data[key] = value end
    result.data = data
    return result
end
local function run(natural: boolean, selected: boolean?, original_definition: {[string]: unknown}?, original_policy: {[string]: unknown}?, retained_id: string?): string?
    local THREAD = selected and "managed_window_selector" or (natural and "managed_window_natural" or "managed_window_thread")
    if retained_id then THREAD = "managed-window-thread:" .. retained_id end
    local definition_ref = retained_id and "bee.managed_window_fixture:retained_definition" or "bee.managed_window_fixture:definition"
    local request_id = retained_id or (natural and "managed-window-natural-request" or "managed-window-request")
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "managed-window-create", title = "Managed window fixture"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local function receive_reply()
        local deadline = time.after("5s")
        local received = channel.select({replies:case_receive(), deadline:case_receive()})
        assert(received.ok and received.channel == replies, "broker reply timed out")
        return received.value
    end
    local broker_policy, broker_error = security.policy("bee:broker_policy")
    if not broker_policy then error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee:core_spawn_boundary")
    if not boundary then error(tostring(boundary_error)) end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    local events = assert(process.events())
    local catalog_deadline = time.after("5s")
    while true do
        local received = channel.select({catalogs:case_receive(), events:case_receive(), catalog_deadline:case_receive()})
        assert(received.ok and received.channel ~= catalog_deadline, "broker catalog timed out")
        if received.channel == catalogs then
            assert(tostring(received.value:from()) == broker)
            break
        elseif received.value.kind == process.event.EXIT and tostring(received.value.from) == broker then
            error("broker exited before catalog: " .. tostring(received.value.result and received.value.result.error))
        end
    end
    local plan, refused = admission.resolve(definition_ref, "window")
    if not plan then error("resolve window plan: " .. tostring(refused and refused.error and refused.error.message)) end
    local request = assert(json.encode({request_id = request_id, definition_ref = definition_ref, brief = retained_id or "managed window",
        thread_id = THREAD, expected_plan_digest = plan.plan_digest}))
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", arguments = selected and {} or {request}}))
    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = receive_reply()
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
        local message = receive_reply()
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-one" and data.op == "attached" then
            assert(data.error_code == "")
            mounted = tostring(data.mount)
        end
    end
    local view = assert(tty.attach(mounted))
    assert(view:send({type = "resize", width = 30, height = 10}))
    if selected then
        if not original_definition or not original_policy then error("missing selector fixtures") end
        local function wait_for(label: string)
            for _ = 1, 100 do
                local snapshot = view:snapshot()
                if snapshot and table.concat(snapshot.rows):find(label, 1, true) then return end
                time.sleep("25ms")
            end
            error("Agent did not show " .. label)
        end
        wait_for("No agent profiles")
        -- An empty picker remains interactive and owns no attempt.
        apply(original_definition)
        assert(view:send({type = "key", key = "r", key_type = "rune", action = "press"}))
        wait_for("Selected agent fixture")
        local before = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
        assert(#(before.records :: {{[string]: unknown}}) == 0, "selector created work before selection")
        -- Change the exact plan displayed, then prove Enter cannot use it.
        local modified = changed(original_policy)
        local modified_data = modified.data :: {[string]: unknown}
        modified_data.start_ms = 11000
        apply(modified)
        assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
        wait_for("Profile changed")
        local refused = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
        assert(#(refused.records :: {{[string]: unknown}}) == 0, "stale selection created work")
        assert(view:send({type = "key", key = "r", key_type = "rune", action = "press"}))
        wait_for("Selected agent fixture")
        assert(view:send({type = "mouse", x = 3, y = 9, button = "left", action = "press"}))
    end
    assert(view:send({type = "paste", text = "hello"}))
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
    local saw = false
    for _ = 1, 100 do
        local frame, frame_error = view:snapshot()
        if not frame then error("snapshot after launch: " .. tostring(frame_error)) end
        if table.concat(frame.rows):find("MANAGED:hello", 1, true) then saw = true; break end
        time.sleep("25ms")
    end
    assert(saw, "broker-mounted PTY did not receive input")
    -- The native process is already accepting input. Recovery metadata must
    -- exist while it runs, rather than first appearing in the close path.
    local live_records = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
    local live_attempt: string? = nil
    for _, record in ipairs(live_records.records :: {{[string]: unknown}}) do
        if record.kind == "attempt.started" and type(record.attempt_id) == "string" then
            if retained_id then assert(record.attempt_id == admission.identities(request_id).attempt_id, "retained launch read another attempt") end
            live_attempt = record.attempt_id
        end
    end
    assert(live_attempt, "running native window has no started attempt")
    local saved = reply(call("bee.threads.carrier:checkpoint", {thread_id = THREAD, attempt_id = live_attempt}).value)
    assert(type(saved.checkpoint_revision) == "number" and saved.checkpoint_revision >= 1,
        "running native window has no committed carrier checkpoint")
    local point = reply(saved.checkpoint)
    assert(point.schema_revision == "bee.carrier.checkpoint@1" and point.binding_ref == "bee.managed_window_fixture:binding",
        "native checkpoint must pin the admitted driver")
    local session_ref: string? = nil
    if retained_id then
        assert(type(point.retained_session_ref) == "string", "retained window checkpoint lost session identity")
        session_ref = point.retained_session_ref :: string
    end
    assert(saved.open_turn_id == nil and point.terminal == nil, "native checkpoint invented a logical turn result")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "detach", op = "bind", workspace_id = WORKSPACE, recipient = ""}))
    local detached = false
    while not detached do
        local message = receive_reply()
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "detach" and data.op == "bind" then detached = data.error_code == "" end
    end
    assert(detached)
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind-two", op = "bind", workspace_id = WORKSPACE,
        id = opened.id, instance_id = opened.instance_id, recipient = owner}))
    local rebound = ""
    while rebound == "" do
        local message = receive_reply()
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-two" and data.op == "attached" then rebound = tostring(data.mount) end
    end
    local next_view = assert(tty.attach(rebound))
    assert(table.concat(next_view:snapshot().rows):find("MANAGED:hello", 1, true), "detach restarted the managed child")
    if not natural then
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
        local closed = false
        while not closed do
            local message = receive_reply()
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
            assert(item.attempt_id == live_attempt, "receipt belongs to another attempt")
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
    return session_ref
end

M.run = function() run(false) end
M.natural = function() run(true) end
M.select = function()
    local definition = assert(registry.get("bee.managed_window_fixture:selector_definition"))
    local policy = assert(registry.get("bee.managed_window_fixture:policy"))
    local ok, failure = pcall(function()
        local hidden = changed(definition)
        local hidden_data = hidden.data :: {[string]: unknown}
        hidden_data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
        apply(hidden)
        run(false, true, definition, policy)
    end)
    apply(definition)
    apply(policy)
    if not ok then error(tostring(failure)) end
end
-- Read the actual child's files after broker close. These checks never create
-- a directory and never run another shell to manufacture the marker.
M.retained = function()
    local roots = assert(registry.get("bee.placement.native:admitted_roots"))
    local mode = assert(registry.get("bee.placement.native:resource_mode"))
    local ok, failure = pcall(function()
        local admitted = changed(roots)
        admitted.data = {roots = {{root_ref = "bee.managed_window_fixture:session_root", access = "write"}}}
        apply(admitted)
        local granted = changed(mode)
        granted.data = {mode = "granted"}
        apply(granted)
        call("bee.resources:associate", {workspace_id = WORKSPACE, name = "retained",
            root_ref = "bee.managed_window_fixture:session_root", subpath = "", allowed_access = "write"})
        local actor = security.actor()
        if not actor then error("fixture has no authenticated actor") end
        local vol = assert(fs.get("bee.placement.native:root"))
        local function marker(session_ref: string): string
            local key, key_error = homes.session_key(actor:id(), session_ref)
            if not key then error(tostring(key_error)) end
            local file, open_error = vol:open("/sessions/" .. key .. "/home/marker.txt", "r")
            if not file then error("retained child marker is absent: " .. tostring(open_error)) end
            local content = file:read(128)
            file:close()
            assert(type(content) == "string", "retained marker is not text")
            return content :: string
        end
        local first = run(false, false, nil, nil, "retained-first")
        if not first then error("first window has no retained session") end
        assert(marker(first) == "retained-first", "normal close lost the first child's files")
        local second = run(false, false, nil, nil, "retained-second")
        if not second then error("second window has no retained session") end
        assert(first ~= second, "distinct launches share a session")
        assert(marker(second) == "retained-second", "second child wrote outside its retained home")
        assert(marker(first) == "retained-first", "second child overwrote the first conversation")
    end)
    apply(roots)
    apply(mode)
    if not ok then error(tostring(failure)) end
end
return M

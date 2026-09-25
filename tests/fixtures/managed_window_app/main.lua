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
type Channel = channel.Channel

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

-- The launch created this thread, so the launch admits the host-issued
-- principal the broker just started. Picker launches cannot name the thread
-- in the open (their definition forbids the override and resolves its named
-- thread instead), so the broker never sees it; the thread owner joins the
-- exact instance the open reported, before driving any input.
local function admit_app(thread_id: string, instance_id: string, idempotency_key: string)
    local thread = call("bee.threads.service:get", {thread_id = thread_id})
    local value = thread.value :: {[string]: unknown}
    local summary = value.summary :: {[string]: unknown}
    local revision = summary.revision
    if type(revision) ~= "number" or revision < 1 then error("admit application thread: thread head is unavailable") end
    call("bee.threads.service:join", {thread_id = thread_id, idempotency_key = idempotency_key,
        member_id = "bee.application:" .. WORKSPACE .. ":" .. instance_id, role = "participant", expected_revision = revision})
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
local function clone_entry(entry: {[string]: unknown}): {[string]: unknown}
    local encoded, encode_error = json.encode(entry)
    if not encoded then error(tostring(encode_error or "encode registry entry")) end
    local copied, decode_error = json.decode(encoded)
    if type(copied) ~= "table" then error(tostring(decode_error or "decode registry entry")) end
    return copied :: {[string]: unknown}
end
local function run(natural: boolean, selected: boolean?, original_definition: {[string]: unknown}?, original_policy: {[string]: unknown}?, retained_id: string?, cancel_activation: boolean?): (string?, string?)
    local THREAD = selected and "managed_window_selector" or (natural and "managed_window_natural" or "managed_window_thread")
    if retained_id then THREAD = "managed-window-thread:" .. retained_id end
    local definition_ref = retained_id and "bee.managed_window_fixture:retained_definition" or "bee.managed_window_fixture:definition"
    local request_id = retained_id or (natural and "managed-window-natural-request" or "managed-window-request")
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "managed-window-create", title = "Managed window fixture"})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local function receive_reply()
        local deadline = time.after("5s")
        local received = channel.select({replies:case_receive(), deadline:case_receive()})
        assert(received.ok and received.channel == replies, "broker reply timed out")
        return received.value
    end
    local broker_policy, broker_error = security.policy("bee.security.desktop:broker_policy")
    if not broker_policy then error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee.security:core_spawn_boundary")
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
    local picker_started = time.now():unix_nano()
    -- A picker launch resolves its named thread at activation, and its
    -- definition forbids naming one in the request, so the open stays
    -- threadless and the launch admits the instance below instead.
    local open_thread: string? = nil
    if not selected then open_thread = THREAD end
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app", thread_id = open_thread, arguments = selected and {} or {request}}))
    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = receive_reply()
        if tostring(message:from()) == broker then
            local data = message:payload():data()
            if type(data) == "table" and data.request_id == "open" and data.op == "open" then opened = data :: {[string]: unknown} end
        end
    end
    assert(opened.error_code == "", "managed app did not become ready: " .. tostring(opened.error))
    local instance_id = assert(opened.instance_id) :: string
    if selected then admit_app(THREAD, instance_id, "managed-window-picker-join") end
    if selected then
        assert(time.now():unix_nano() - picker_started < 1000000000,
            "Agent picker readiness waited for profile discovery")
    end
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
        local function wait_without(label: string)
            for _ = 1, 100 do
                local snapshot = view:snapshot()
                if snapshot and not table.concat(snapshot.rows):find(label, 1, true) then return end
                time.sleep("25ms")
            end
            error("Agent did not clear " .. label)
        end
        wait_for("No agent profiles")
        -- An empty picker remains interactive and owns no attempt.
        apply(original_definition)
        assert(view:send({type = "key", key = "r", key_type = "rune", action = "press"}))
        wait_for("Selected agent fixture")
        if cancel_activation then
            local resource_state = reply(call("bee.resources.binding:list", {workspace_id = WORKSPACE}).value)
            local grants_before = #(resource_state.grants :: {{[string]: unknown}})
            assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
            wait_for("Starting Agent")
            assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}), "duplicate Enter was not accepted as input")
            assert(view:send({type = "resize", width = 36, height = 12}))
            local resized = false
            for _ = 1, 40 do
                local snapshot = view:snapshot()
                if snapshot and #snapshot.rows == 12 and table.concat(snapshot.rows):find("Starting Agent", 1, true) then resized = true; break end
                time.sleep("25ms")
            end
            assert(resized, "Agent picker did not resize during activation")
            local closing = time.now():unix_nano()
            local escaped = channel.new(1)
            coroutine.spawn(function()
                escaped:send(view:send({type = "key", key = "", key_type = "escape", action = "press"}))
            end)
            local close_deadline = closing + 1500000000
            while time.now():unix_nano() < close_deadline do
                if not view:snapshot() then break end
                time.sleep("25ms")
            end
            assert(not view:snapshot(), "Escape did not close the activating picker")
            assert(time.now():unix_nano() - closing < 1500000000, "activating picker did not close within bounded admission cleanup")
            local escaped_result = channel.select({escaped:case_receive(), time.after("2s"):case_receive()})
            assert(escaped_result.ok and escaped_result.channel == escaped and escaped_result.value == true,
                "activating picker did not finish close after admission cleanup")
            local after = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
            for _, record in ipairs(after.records :: {{[string]: unknown}}) do
                assert(record.kind ~= "action.admitted" and record.kind ~= "attempt.prepared"
                    and record.kind ~= "attempt.started" and record.kind ~= "receipt",
                    "cancelled picker crossed the carrier lifecycle boundary")
            end
            local resources_after = reply(call("bee.resources.binding:list", {workspace_id = WORKSPACE}).value)
            assert(#(resources_after.grants :: {{[string]: unknown}}) == grants_before,
                "cancelled picker retained an attempt-bound resource grant")
            view:close()
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "open-after-cancel", op = "open",
                workspace_id = WORKSPACE, definition_id = "bee.harness.window:app", arguments = {}}))
            opened = nil
            while not opened do
                local message = receive_reply()
                local data = message:payload():data()
                if tostring(message:from()) == broker and type(data) == "table"
                    and data.request_id == "open-after-cancel" and data.op == "open" then opened = data :: {[string]: unknown} end
            end
            assert(opened.error_code == "", "replacement picker did not become ready: " .. tostring(opened.error))
            admit_app(THREAD, assert(opened.instance_id) :: string, "managed-window-picker-rejoin")
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "bind-after-cancel", op = "bind",
                workspace_id = WORKSPACE, id = opened.id, instance_id = opened.instance_id, recipient = owner}))
            mounted = ""
            while mounted == "" do
                local message = receive_reply()
                local data = message:payload():data()
                if tostring(message:from()) == broker and type(data) == "table"
                    and data.request_id == "bind-after-cancel" and data.op == "attached" then
                    assert(data.error_code == "", tostring(data.error)); mounted = tostring(data.mount)
                end
            end
            view = assert(tty.attach(mounted))
            assert(view:send({type = "resize", width = 30, height = 10}))
            wait_for("Selected agent fixture")
        end
        local before = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
        assert(#(before.records :: {{[string]: unknown}}) == 0, "selector created work before selection")
        -- Change the exact plan displayed, then prove Enter cannot use it.
        local modified = changed(original_policy)
        local modified_data = modified.data :: {[string]: unknown}
        modified_data.start_ms = 11000
        apply(modified)
        assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
        -- First-use setup now rejects the stale plan before admission. Its
        -- full message is clipped at this deliberately narrow viewport.
        wait_for("selected launch plan")
        local refused = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
        assert(#(refused.records :: {{[string]: unknown}}) == 0, "stale selection created work")
        assert(view:send({type = "key", key = "r", key_type = "rune", action = "press"}))
        wait_without("selected launch plan")
        wait_for("Selected agent fixture")
        assert(view:send({type = "mouse", x = 3, y = 9, button = "left", action = "press"}))
    end
    if selected then
        local launched = false
        for _ = 1, 160 do
            local page = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 32}).value)
            for _, record in ipairs(page.records :: {{[string]: unknown}}) do
                if record.kind == "attempt.started" then launched = true; break end
            end
            if launched then break end
            time.sleep("25ms")
        end
        assert(launched, "Agent picker did not start the selected child")
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
    -- Input worked before the owner acknowledged the application checkpoint.
    local checkpoint_timeout = assert(time.after("5s"))
    local incoming = channel.select({checkpoints:case_receive(), checkpoint_timeout:case_receive()})
    assert(incoming.ok and incoming.channel == checkpoints, "Agent did not queue an application checkpoint")
    assert(tostring(incoming.value:from()) == broker, "checkpoint did not come through the broker")
    local application_checkpoint = reply(incoming.value:payload():data())
    assert(application_checkpoint.resume_schema == "bee.agent.window@1", "Agent checkpoint schema")
    local application_state = reply(json.decode(application_checkpoint.resume_state :: string))
    local field_count = 0
    for key in pairs(application_state) do
        assert(key == "definition_ref" or key == "plan_digest" or key == "origin_request_id" or key == "previous_attempt_id" or key == "thread_id",
            "Agent checkpoint carried non-identity data")
        field_count = field_count + 1
    end
    assert(field_count == 5, "Agent checkpoint is incomplete")
    assert(application_state.thread_id == THREAD, "Agent checkpoint switched threads")
    if not selected then assert(application_state.origin_request_id == request_id, "Agent checkpoint changed origin") end
    assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = application_checkpoint.request_id,
        error_code = natural and "persistence_refused" or "", error = natural and "Fixture refused Agent save" or ""}))
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
    assert(application_state.previous_attempt_id == live_attempt, "Agent checkpoint did not advance to its started attempt")
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
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-two" and data.op == "attached" then
            assert(data.resume_state == (natural and "" or application_checkpoint.resume_state), "rebind exposed an unacknowledged Agent checkpoint")
            rebound = tostring(data.mount)
        end
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
        local retired = false
        local deadline = time.after("5s")
        while not retired do
            local received = channel.select({replies:case_receive(), deadline:case_receive()})
            assert(received.ok and received.channel == replies, "natural PTY completion did not retire the broker application")
            local message = received.value
            if tostring(message:from()) == broker then
                local data = message:payload():data()
                if type(data) == "table" and data.op == "closed" and data.id == opened.id and data.instance_id == opened.instance_id then
                    retired = true
                end
            end
        end
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
    process.unlisten(catalogs); process.unlisten(replies); process.unlisten(checkpoints)
    local finished = assert(opened)
    return session_ref, assert(finished.instance_id) :: string
end

-- Broker replies are the owner's recovery projection. A checkpoint belongs in
-- that projection only after this owner acknowledges persistence. The fixture
-- app forwards its authentic broker receipts, which makes each assertion wait
-- for the actual acknowledgement instead of relying on channel ordering.
local function checkpoint_ack_body(original_admission: {[string]: unknown})
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local receipts = assert(process.listen("bee.fixture.checkpoint.receipt", {message = true}))
    local app_ready = assert(process.listen("bee.fixture.checkpoint.ready", {message = true}))
    local sent = assert(process.listen("bee.fixture.checkpoint.sent", {message = true}))
    local events = assert(process.events())
    local broker_policy = assert(security.policy("bee.security.desktop:broker_policy"))
    local boundary = assert(security.policy("bee.security:core_spawn_boundary"))
    local fixture_admission = changed(original_admission)
    local fixture_data = fixture_admission.data :: {[string]: unknown}
    local bindings: {{[string]: unknown}} = {}
    for _, binding in ipairs(fixture_data.bindings :: {{[string]: unknown}}) do
        local copy: {[string]: unknown} = {}
        for key, value in pairs(binding) do copy[key] = value end
        bindings[#bindings + 1] = copy
    end
    bindings[#bindings + 1] = {definition_id = "bee.managed_window_fixture:checkpoint_app", policies = {}}
    fixture_data.bindings = bindings
    apply(fixture_admission)
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(security.new_scope({broker_policy, boundary})):spawn_monitored("bee.applications:broker", "bee:workers", owner, appearance.defaults())))
    local function wait_message(subscription: Channel<process.Message>, label: string, timeout: string?): process.Message
        local deadline = time.after(timeout or "5s")
        local selected = channel.select({subscription:case_receive(), events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, label .. " timed out")
        if selected.channel == events then error(label .. ": broker exited") end
        return selected.value
    end
    local function receive_checkpoint(state: string, action: "accept" | "refuse" | "lose"): string
        local message = wait_message(checkpoints, "checkpoint " .. state)
        assert(tostring(message:from()) == broker)
        local data: unknown = message:payload():data()
        assert(type(data) == "table" and data.resume_state == state, "unexpected checkpoint state")
        if action == "accept" then
            assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = data.request_id, error_code = "", error = ""}))
        elseif action == "refuse" then
            assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = data.request_id,
                error_code = "persistence_refused", error = "Fixture owner refused checkpoint"}))
        end
        return data.request_id :: string
    end
    local function receive_receipt(request_id: string, code: string, app_pid: string, timeout: string?)
        local message = wait_message(receipts, "checkpoint receipt " .. code, timeout)
        local data: unknown = message:payload():data()
        assert(tostring(message:from()) == app_pid and type(data) == "table" and data.request_id == request_id and data.error_code == code, "unexpected checkpoint receipt")
    end
    local function receive_sent(state: string, app_pid: string): string
        local message = wait_message(sent, "checkpoint sent " .. state)
        local data: unknown = message:payload():data()
        assert(tostring(message:from()) == app_pid and type(data) == "table" and data.state == state and type(data.request_id) == "string", "unexpected checkpoint request")
        return data.request_id
    end
    local initial = "acknowledged-initial"
    local refused = "refused-newer"
    local acknowledged = "acknowledged-newer"
    local catalog_message = wait_message(catalogs, "broker startup")
    assert(tostring(catalog_message:from()) == broker and type(catalog_message:payload():data()) == "table", "broker did not publish catalog")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "checkpoint-open", op = "open", workspace_id = WORKSPACE,
        definition_id = "bee.managed_window_fixture:checkpoint_app", resume_schema = "checkpoint-fixture.v1", resume_state = initial}))
    local ready_message = wait_message(app_ready, "checkpoint fixture ready")
    local ready_data: unknown = ready_message:payload():data()
    assert(type(ready_data) == "table" and type(ready_data.pid) == "string" and tostring(ready_message:from()) == ready_data.pid, "invalid checkpoint fixture readiness")
    local app_pid = ready_data.pid
    local initial_request = receive_sent(initial, app_pid)
    receive_checkpoint(initial, "accept")
    receive_receipt(initial_request, "", app_pid)
    local opened: {[string]: unknown}? = nil
    while not opened do
        local message = wait_message(replies, "checkpoint fixture open")
        assert(tostring(message:from()) == broker)
        local data: unknown = message:payload():data()
        if type(data) == "table" and data.request_id == "checkpoint-open" and data.op == "open" then
            assert(data.error_code == "", "checkpoint fixture did not become ready")
            opened = data :: {[string]: unknown}
        end
    end
    local function attached(request_id: string, expected: string): string
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = request_id, op = "bind", workspace_id = WORKSPACE,
            id = opened.id, instance_id = opened.instance_id, recipient = owner}))
        while true do
            local message = wait_message(replies, request_id)
            assert(tostring(message:from()) == broker)
            local data: unknown = message:payload():data()
            if type(data) == "table" and data.request_id == request_id and data.op == "attached" then
                assert(data.error_code == "", request_id .. ": attachment failed")
                assert(data.resume_state == expected, request_id .. ": broker exposed an unacknowledged checkpoint")
                return data.mount :: string
            end
        end
        error("unreachable attachment wait")
    end
    local view_id = opened.id :: string
    local instance_id = opened.instance_id :: string
    attached("checkpoint-initial", initial)
    assert(process.send(app_pid, "bee.fixture.checkpoint.command", "refuse"))
    local refused_request = receive_sent(refused, app_pid)
    receive_checkpoint(refused, "refuse")
    receive_receipt(refused_request, "persistence_refused", app_pid)
    attached("checkpoint-refused", initial)
    assert(process.send(app_pid, "bee.fixture.checkpoint.command", "accept"))
    local acknowledged_request = receive_sent(acknowledged, app_pid)
    receive_checkpoint(acknowledged, "accept")
    receive_receipt(acknowledged_request, "", app_pid)
    attached("checkpoint-acknowledged", acknowledged)
    assert(process.send(app_pid, "bee.fixture.checkpoint.command", "lose"))
    local lost_request = receive_sent("lost-newer", app_pid)
    receive_checkpoint("lost-newer", "lose")
    receive_receipt(lost_request, "timeout", app_pid, "7s")
    local retained_mount = attached("checkpoint-timeout", acknowledged)
    local view = assert(tty.attach(retained_mount))
    local view_handle = assert(view:handle())
    assert(view:send({type = "resize", width = 36, height = 12}))
    local function wait_snapshot(label: string): boolean
        for _ = 1, 200 do
            local snapshot = view:snapshot()
            if snapshot and snapshot.width == 36 and snapshot.height == 12
                and table.concat(snapshot.rows):find(label, 1, true) then return true end
            time.sleep("25ms")
        end
        return false
    end
    assert(wait_snapshot("CHECKPOINT APP 1"), "initial checkpoint app did not retain its resized viewport")
    local original_app = assert(registry.get("bee.managed_window_fixture:checkpoint_app"))
    local updated_app = clone_entry(original_app)
    local updated_data = updated_app.data :: {[string]: unknown}
    assert(type(updated_data.source) == "string", "checkpoint app lost its executable source")
    local updated_meta = updated_app.meta :: {[string]: unknown}
    local application = updated_meta.application :: {[string]: unknown}
    application.revision = "2"
    apply(updated_app)
    local replacement_pid = ""
    local replacement_ready = false
    local replacement_deadline = time.after("7s")
    while not replacement_ready do
        local selected = channel.select({app_ready:case_receive(), replies:case_receive(), events:case_receive(), replacement_deadline:case_receive()})
        assert(selected.ok and selected.channel ~= replacement_deadline, "checkpoint fixture replacement timed out")
        if selected.channel == events then error("broker exited during checkpoint fixture replacement") end
        if selected.channel == app_ready then
            local message = selected.value
            local data: unknown = message:payload():data()
            assert(type(data) == "table" and type(data.pid) == "string", "invalid replacement readiness")
            assert(tostring(message:from()) == data.pid, "replacement readiness sender mismatch")
            assert(data.definition_revision == "2", "replacement launched the old definition")
            assert(data.resume_state == acknowledged, "replacement lost the last acknowledged checkpoint")
            replacement_pid = data.pid
            replacement_ready = true
        elseif selected.channel == replies then
            local message = selected.value
            if tostring(message:from()) == broker then
                local data: unknown = message:payload():data()
                if type(data) == "table" and data.id == view_id and data.instance_id == instance_id then
                    assert(data.op ~= "closed", "replacement closed the application")
                    assert(data.op ~= "open", "replacement created a fresh application")
                    assert(data.op ~= "attached", "replacement created a fresh attachment")
                end
            end
        end
    end
    local quiet = time.after("250ms")
    while true do
        local selected = channel.select({replies:case_receive(), events:case_receive(), quiet:case_receive()})
        if not selected.ok or selected.channel == quiet then break end
        if selected.channel == events then error("broker exited after checkpoint fixture replacement") end
        local message = selected.value
        if tostring(message:from()) == broker then
            local data: unknown = message:payload():data()
            if type(data) == "table" and data.id == view_id and data.instance_id == instance_id then
                assert(data.op ~= "closed", "replacement closed the application")
                assert(data.op ~= "open", "replacement created a fresh application")
                assert(data.op ~= "attached", "replacement created a fresh attachment")
            end
        end
    end
    assert(replacement_pid ~= app_pid, "replacement reused the old execution")
    assert(view:handle() == view_handle, "replacement changed the attached view")
    assert(wait_snapshot("CHECKPOINT APP 2"), "replacement did not render the new definition")
    local replacement_snapshot = assert(view:snapshot())
    assert(replacement_snapshot.width == 36 and replacement_snapshot.height == 12,
        "replacement lost the controller viewport geometry")

    -- Drain the replacement's startup checkpoint before creating the exact
    -- shutdown race: a later pending checkpoint fences v3 after v2 exits.
    local replacement_initial = receive_sent(initial, replacement_pid)
    receive_checkpoint(initial, "accept")
    receive_receipt(replacement_initial, "", replacement_pid)
    assert(process.send(replacement_pid, "bee.fixture.checkpoint.command", "lose"))
    receive_sent("lost-newer", replacement_pid)
    local pending_shutdown_write = receive_checkpoint("lost-newer", "lose")
    assert(process.monitor(replacement_pid))
    local third_app = clone_entry(updated_app)
    local third_meta = third_app.meta :: {[string]: unknown}
    local third_application = third_meta.application :: {[string]: unknown}
    third_application.revision = "3"
    apply(third_app)
    local replacement_exit = time.after("5s")
    while true do
        local selected = channel.select({events:case_receive(), replacement_exit:case_receive()})
        assert(selected.ok and selected.channel ~= replacement_exit, "replacement did not exit for the pending update")
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == replacement_pid then break end
        if event.kind == process.event.EXIT and tostring(event.from) == broker then error("broker exited during replacement shutdown") end
    end
    -- Let the broker consume the same EXIT before workspace cleanup observes
    -- the replacement record. The pending write remains deliberately held.
    time.sleep("500ms")
    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "checkpoint-replacement-shutdown",
        op = "shutdown", workspace_id = WORKSPACE}))
    assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = pending_shutdown_write,
        error_code = "", error = ""}))
    local shutdown_deadline = time.after("5s")
    while true do
        local selected = channel.select({replies:case_receive(), app_ready:case_receive(), events:case_receive(), shutdown_deadline:case_receive()})
        assert(selected.ok and selected.channel ~= shutdown_deadline, "replacement shutdown timed out")
        if selected.channel == app_ready then error("shutdown launched a replacement after v2 exited") end
        if selected.channel == events then error("broker exited before shutdown acknowledgement") end
        local message = selected.value
        assert(tostring(message:from()) == broker)
        local data: unknown = message:payload():data()
        if type(data) == "table" and data.request_id == "checkpoint-replacement-shutdown" and data.op == "shutdown" then
            assert(data.error_code == "", "shutdown retained an exited replacement: " .. tostring(data.error))
            break
        end
    end
    view:close()
    process.terminate(broker)
    for _, subscription in ipairs({catalogs, replies, checkpoints, receipts, app_ready, sent}) do process.unlisten(subscription) end
end

local function checkpoint_ack()
    local original_admission = assert(registry.get("bee.security:application_admission"))
    local original_app = assert(registry.get("bee.managed_window_fixture:checkpoint_app"))
    local ok, failure = pcall(checkpoint_ack_body, original_admission)
    apply(original_app)
    apply(original_admission)
    if not ok then error(tostring(failure)) end
end

M.run = function() run(false) end
M.checkpoint_ack = checkpoint_ack
M.natural = function() run(true) end
M.select = function()
    local definition = assert(registry.get("bee.managed_window_fixture:selector_definition"))
    local policy = assert(registry.get("bee.managed_window_fixture:policy"))
    local defaults: {{[string]: unknown}} = {}
    local ok, failure = pcall(function()
        local found = assert(registry.find({["meta.type"] = "bee.launch_definition"}))
        for _, entry in ipairs(found) do
            local meta = entry.meta :: {[string]: unknown}
            if meta.test_support ~= true then
                defaults[#defaults + 1] = entry
                local hidden_default = changed(entry)
                local data = hidden_default.data :: {[string]: unknown}
                data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
                apply(hidden_default)
            end
        end
        local configured = changed(definition)
        local configured_data = configured.data :: {[string]: unknown}
        configured_data.session_resource = "session"
        local hidden = changed(configured)
        local hidden_data = hidden.data :: {[string]: unknown}
        hidden_data.presentation = {start_menu = false, fullscreen = false, reuse = "never"}
        apply(hidden)
        run(false, true, configured, policy, nil, true)
    end)
    apply(definition)
    apply(policy)
    for _, entry in ipairs(defaults) do apply(reply(entry)) end
    if not ok then error(tostring(failure)) end
end
-- Read the actual child's files after broker close. These checks never create
-- a directory and never run another shell to manufacture the marker.
M.retained = function()
    local roots = assert(registry.get("bee:resource_roots"))
    local mode = assert(registry.get("bee:placement_resource_mode"))
    local ok, failure = pcall(function()
        local admitted = changed(roots)
        admitted.data = {roots = {{root_ref = "bee.managed_window_fixture:session_root", access = "write"}}}
        apply(admitted)
        local granted = changed(mode)
        granted.data = {mode = "granted"}
        apply(granted)
        call("bee.resources.binding:associate", {workspace_id = WORKSPACE, name = "retained",
            root_ref = "bee.managed_window_fixture:session_root", subpath = "", allowed_access = "write"})
        local actor = security.actor()
        if not actor then error("fixture has no authenticated actor") end
        local vol = assert(fs.get("bee.placement.native:root"))
        -- Retained sessions are owned by the launch principal that created
        -- them, so the key derives from the application instance, never from
        -- this launcher.
        local function marker(session_ref: string, instance_id: string): string
            local key, key_error = homes.session_key("bee.application:" .. WORKSPACE .. ":" .. instance_id, session_ref)
            if not key then error(tostring(key_error)) end
            local file, open_error = vol:open("/sessions/" .. key .. "/home/marker.txt", "r")
            if not file then error("retained child marker is absent: " .. tostring(open_error)) end
            local content = file:read(128)
            file:close()
            assert(type(content) == "string", "retained marker is not text")
            return content :: string
        end
        local first, first_instance = run(false, false, nil, nil, "retained-first")
        if not first or not first_instance then error("first window has no retained session") end
        assert(marker(first, first_instance) == "retained-first", "normal close lost the first child's files")
        local second, second_instance = run(false, false, nil, nil, "retained-second")
        if not second or not second_instance then error("second window has no retained session") end
        assert(first ~= second, "distinct launches share a session")
        assert(marker(second, second_instance) == "retained-second", "second child wrote outside its retained home")
        assert(marker(first, first_instance) == "retained-first", "second child overwrote the first conversation")
    end)
    apply(roots)
    apply(mode)
    if not ok then error(tostring(failure)) end
end
return M

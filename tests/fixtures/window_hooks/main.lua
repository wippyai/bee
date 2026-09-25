-- MIT. Real native-window hook acceptance fixture.
local io = require("io")
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
local store = require("store")

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

-- Nonsecret markers the fixture child prints, in first-seen order. Terminal
-- content beyond these markers is never reported.
local function collect_markers(seen: {string}, screen: string)
    for marker in screen:gmatch("HOOK_[%u_]+:[%w%-]+") do
        local known = false
        for _, previous in ipairs(seen) do
            if previous == marker then known = true; break end
        end
        if not known then table.insert(seen, marker) end
    end
end

-- Placement attempts and their evidence, the owner's record of how each native
-- child started and ended. Evidence carries no credential bytes.
local function placement_report(): string
    local db, open_error = store.open()
    if not db then return "placement store unavailable: " .. tostring(open_error) end
    local lines: {string} = {}
    local attempts = db:query([[SELECT attempt_id, execution_state, cleanup_state, exit_code, exit_signal,
        exit_source, session_ref, home_key FROM bee_placement_attempts ORDER BY created_at]]) or {}
    for _, row in ipairs(attempts :: {{[string]: unknown}}) do
        table.insert(lines, string.format("attempt %s execution=%s cleanup=%s exit_code=%s exit_signal=%s exit_source=%s session=%s home=%s",
            tostring(row.attempt_id), tostring(row.execution_state), tostring(row.cleanup_state), tostring(row.exit_code),
            tostring(row.exit_signal), tostring(row.exit_source), tostring(row.session_ref), tostring(row.home_key)))
    end
    local evidence = db:query([[SELECT attempt_id, sequence, kind, detail FROM bee_placement_evidence
        ORDER BY attempt_id, sequence LIMIT 80]]) or {}
    for _, row in ipairs(evidence :: {{[string]: unknown}}) do
        table.insert(lines, string.format("  %s #%s %s: %s", tostring(row.attempt_id), tostring(row.sequence),
            tostring(row.kind), tostring(row.detail)))
    end
    db:release()
    return table.concat(lines, "\n")
end

-- Command hooks submit through the host-selected `hook-post` executable, which
-- reports acceptance by its exit status; direct hooks report the HTTP status.
local function execute(crashed: boolean, cancel_recovery: boolean, pending_hook: boolean, command_hooks: boolean)
    local definition = command_hooks and "bee.window.hooks.fixture:command_definition" or "bee.window.hooks.fixture:definition"
    local accepted_result = command_hooks and "exit-0" or "http-202"
    -- 1. Open gateway listener under configured loopback endpoint
    local address = endpoint()
    local opened_gateway = call("bee.gateway.binding:open", {address = address})
    assert(opened_gateway.value ~= nil, "failed to open gateway listener")

    -- The host explicitly admits a session root in this disposable fixture.
    local roots = assert(registry.get("bee:resource_roots"))
    roots.data = {roots = {{root_ref = "bee.window.hooks.fixture:session_root", access = "write"}}}
    local changes = registry.snapshot():changes()
    changes:update(roots)
    assert(changes:apply())
    call("bee.resources.binding:associate", {workspace_id = WORKSPACE, name = "retained",
        root_ref = "bee.window.hooks.fixture:session_root", subpath = "", allowed_access = "write"})

    -- 2. Create the target thread
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "window-hooks-create", title = "Window hooks fixture"})

    -- 3. Spawn real native application broker
    local owner = tostring(process.pid())
    local catalogs = assert(process.listen("bee.application.catalog", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.application.checkpoint", {message = true}))
    local broker_policy, broker_error = security.policy("bee.security.desktop:broker_policy")
    if not broker_policy then error(tostring(broker_error)) end
    local boundary, boundary_error = security.policy("bee.security:core_spawn_boundary")
    if not boundary then error(tostring(boundary_error)) end
    local scope = security.new_scope({broker_policy, boundary})
    local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner, ["bee.workspace_id"] = WORKSPACE})
        :with_scope(scope):spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults())))
    assert(catalogs:receive():from() == broker)

    -- 4. Resolve plan and open bee.harness.window:app
    local plan, refused = admission.resolve(definition, "window")
    if not plan then error("resolve window plan: " .. tostring(refused and refused.error and refused.error.message)) end

    local request = assert(json.encode({
        request_id = "window-hooks-req",
        definition_ref = definition,
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
        thread_id = THREAD,
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

    local checkpoint_deadline = time.after("3s")
    local checkpoint_event = channel.select({checkpoints:case_receive(), checkpoint_deadline:case_receive()})
    assert(checkpoint_event.channel ~= checkpoint_deadline and checkpoint_event.ok, "window checkpoint was not delivered")
    local checkpoint_message = checkpoint_event.value
    assert(tostring(checkpoint_message:from()) == broker, "window checkpoint came from an unauthenticated sender")
    local checkpoint_data = checkpoint_message:payload():data()
    assert(type(checkpoint_data) == "table" and checkpoint_data.version == 1
        and checkpoint_data.resume_schema == "bee.agent.window@1" and type(checkpoint_data.resume_state) == "string",
        "window checkpoint has an invalid persisted state")
    local saved_state = checkpoint_data.resume_state :: string
    assert(process.send(broker, "bee.application.persisted", {version = 1, request_id = checkpoint_data.request_id,
        error_code = "", error = ""}))


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

    -- 6. Verify child submitted hook and the real gateway accepted it
    local hook_submitted = false
    local hook_status = "not observed"
    for _ = 1, 160 do
        local frame, frame_error = view:snapshot()
        if frame then
            local text = table.concat(frame.rows)
            local result = text:match("HOOK_TOOL:([%w%-]+)")
            if result then hook_status = result end
            if text:find("HOOK_TOOL:" .. accepted_result, 1, true) then
                hook_submitted = true
                break
            end
        end
        time.sleep("50ms")
    end
    -- Keep diagnostics to the nonsecret status marker, never configuration,
    -- authorization headers or arbitrary terminal content.
    assert(hook_submitted, "actual hook was not accepted by real gateway (expected HOOK_TOOL:" .. accepted_result .. "; observed " .. hook_status .. ")")

    -- 7. Verify terminal input is functional
    local input_started = time.now():unix_nano()
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
    assert(time.now():unix_nano() - input_started < 1000000000, "PTY input waited for the delayed gateway claim")

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

    -- Commit and acknowledgment are separate asynchronous operations.
    assert(committed_binding_id and committed_binding_id ~= "", "hook omitted binding identity")
    assert(committed_event_id and committed_event_id ~= "", "hook omitted event identity")
    local acknowledged = false
    for _ = 1, 100 do
        local queue_res = call("bee.gateway.binding:hook_queue", {binding_id = committed_binding_id})
        local queue_val = reply(queue_res.value)
        local found_hook: {[string]: unknown}? = nil
        for _, h in ipairs(queue_val.hooks :: {{[string]: unknown}}) do
            if committed_event_id and h.event_id == committed_event_id then
                found_hook = h
                break
            end
        end
        if found_hook and found_hook.status == "committed" then acknowledged = true; break end
        time.sleep("25ms")
    end
    assert(acknowledged, "gateway did not acknowledge the committed hook")

    -- The actual app publishes activity through the existing broker title API.
    local title_deadline = time.after("3s")
    local titled = false
    while not titled do
        local event = channel.select({replies:case_receive(), title_deadline:case_receive()})
        if event.channel == title_deadline or not event.ok then break end
        local message = event.value
        if tostring(message:from()) == broker then
            local data: unknown = message:payload():data()
            if type(data) == "table" and data.op == "title" and data.id == opened.id
                and data.instance_id == opened.instance_id then
                assert(data.title == "Window hooks fixture" or data.title == "Window hooks fixture · Using tool"
                    or data.title == "Window hooks fixture · Session started",
                    "unexpected fixture hook title: " .. tostring(data.title))
                titled = data.title == "Window hooks fixture · Using tool"
            end
        end
    end
    assert(titled, "committed native hook did not reach the broker title API")

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


    if pending_hook then
        assert(view:send({type = "paste", text = "pending-hook"}))
        assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
        local accepted = false
        for _ = 1, 60 do
            local frame = view:snapshot()
            if frame and table.concat(frame.rows):find("HOOK_PENDING:" .. accepted_result, 1, true) then accepted = true; break end
            time.sleep("10ms")
        end
        assert(accepted, "additional hook was not accepted before the crash")
        local queue = reply(call("bee.gateway.binding:hook_queue", {binding_id = committed_binding_id}).value)
        local unclaimed = false
        for _, hook in ipairs(queue.hooks :: {{[string]: unknown}}) do
            local fields = reply(hook.fields)
            if fields.tool_use_id == "toolu_pending" then
                unclaimed = hook.status == "queued" and hook.claimed_epoch == 0
            end
        end
        assert(unclaimed, "crash fixture must interrupt an accepted, unclaimed hook")
    end

    -- 11. Close application and verify clean shutdown
    if crashed then
        local db = assert(store.open())
        local recorded = assert(store.row(db, admission.identities("window-hooks-req").attempt_id))
        db:release()
        assert(type(recorded.runner_pid) == "string", "fixture has no recorded owner actor")
        assert(process.terminate(recorded.runner_pid :: string))
    else
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close", op = "close", workspace_id = WORKSPACE, id = opened.id}))
    end
    local closed = false
    while not closed do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "close" and data.op == "close" then
            assert(data.error_code == "", "managed window close failed: " .. tostring(data.error))
            closed = true
        elseif crashed and tostring(message:from()) == broker and type(data) == "table"
            and data.op == "closed" and data.id == opened.id then
            closed = true
        end
    end
    assert(closed, "managed window close failed")

    -- Broker completion observes EXIT, so the durable receipt must exist now.
    local final_page = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64}).value)
    local receipts = 0
    for _, item in ipairs(final_page.records :: {{[string]: unknown}}) do
        if item.kind == "receipt" then
            receipts = receipts + 1
            local body = reply(item.body)
            assert(body.scope == "attempt" and body.outcome == "cancelled", "expected cancelled receipt")
        end
    end
    assert(receipts == (crashed and 0 or 1), "unexpected receipt count before recovery")
    local tool_hooks = 0
    local lifecycle_hooks = 0
    for _, record in ipairs(final_page.records :: {{[string]: unknown}}) do
        assert(record.kind ~= "turn.request" and record.kind ~= "turn.end", "native hooks invented a logical turn")
        if record.kind == "observation" then
            local body = reply(record.body)
            if tostring(body.event_key):find("^hook:") and type(body.data) == "table" then
                local data = body.data :: {[string]: unknown}
                local decoded = data.payload_json and json.decode(tostring(data.payload_json)) or nil
                local payload = type(decoded) == "table" and decoded :: {[string]: unknown} or {}
                if payload.event == "SessionStart" then lifecycle_hooks = lifecycle_hooks + 1
                elseif payload.event == "PreToolUse" then tool_hooks = tool_hooks + 1
                else error("unexpected committed hook event: " .. tostring(payload.event)) end
            end
        end
    end
    assert(tool_hooks == 1, "replayed child submissions must leave exactly one tool hook observation")
    assert(lifecycle_hooks == 1, "provider startup must leave exactly one session lifecycle observation")

    -- 13. Gracefully continue the closed window through the broker's real
    -- checkpoint restore path, using the application's acknowledged checkpoint.
    view:close()
    local previous_attempt_id = admission.identities("window-hooks-req").attempt_id
    assert(process.send(broker, "bee.app.request", {
        version = 1,
        request_id = "continuation-open",
        op = "open",
        workspace_id = WORKSPACE,
        definition_id = "bee.harness.window:app",
        restore_instance_id = opened.instance_id,
        restore_view_id = opened.id,
        resume_schema = "bee.agent.window@1",
        resume_state = saved_state,
        arguments = {},
    }))

    local continued: {[string]: unknown}? = nil
    while not continued do
        local message = assert(replies:receive())
        if tostring(message:from()) == broker then
            local data = message:payload():data()
            if type(data) == "table" and data.request_id == "continuation-open" and data.op == "open" then
                continued = data :: {[string]: unknown}
            end
        end
    end
    if continued.error_code ~= "" then
        local checkpoint = reply(call("bee.threads.carrier:checkpoint", {thread_id = THREAD, attempt_id = previous_attempt_id}).value)
        local status_db = assert(store.open())
        local attempt = assert(store.attempt(status_db, previous_attempt_id), "previous placement attempt is missing")
        status_db:release()
        error("window continuation did not become ready: " .. tostring(continued.error) .. "; code=" .. tostring(continued.error_code)
            .. "; previous thread attempt=" .. tostring(checkpoint.attempt_state)
            .. "; native execution=" .. tostring(attempt.execution_state)
            .. "; cleanup=" .. tostring(attempt.cleanup_state))
    end
    assert(continued.id == opened.id and continued.instance_id == opened.instance_id, "continuation did not restore the application identity")

    assert(process.send(broker, "bee.app.request", {
        version = 1,
        request_id = "bind-two",
        op = "bind",
        workspace_id = WORKSPACE,
        id = continued.id,
        instance_id = continued.instance_id,
        recipient = owner,
    }))
    local mounted_two = ""
    while mounted_two == "" do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "bind-two" and data.op == "attached" then
            assert(data.error_code == "")
            mounted_two = tostring(data.mount)
        end
    end
    local view_two = assert(tty.attach(mounted_two))
    assert(view_two:send({type = "resize", width = 80, height = 24}))

    if cancel_recovery then
        local recovering = false
        for _ = 1, 30 do
            local frame = view_two:snapshot()
            if frame and table.concat(frame.rows):find("Restoring Agent", 1, true) then recovering = true; break end
            time.sleep("25ms")
        end
        assert(recovering, "restore did not show its responsive recovery surface")
        assert(process.send(broker, "bee.app.request", {version = 1, request_id = "cancel-recovery", op = "close",
            workspace_id = WORKSPACE, id = continued.id}))
        local deadline = time.after("2s")
        local cancelled = false
        while not cancelled do
            local selected = channel.select({replies:case_receive(), deadline:case_receive()})
            if selected.channel == deadline or not selected.ok then break end
            local message = selected.value
            local data = message:payload():data()
            if tostring(message:from()) == broker and type(data) == "table"
                and data.request_id == "cancel-recovery" and data.op == "close" then
                assert(data.error_code == "", "recovery close was refused")
                cancelled = true
            end
        end
        assert(cancelled, "recovery close waited on hook admission")
        -- Let the delayed admission finish if cancellation failed to retire it.
        -- It must never create a new native process after this view closes.
        time.sleep("6s")
        local db = assert(store.open())
        local attempts = assert(db:query("SELECT attempt_id FROM bee_placement_attempts"))
        db:release()
        assert(#attempts == 1 and attempts[1].attempt_id == previous_attempt_id,
            "cancelled recovery created another native attempt")
        view_two:close()
        process.terminate(broker)
        process.unlisten(catalogs); process.unlisten(replies); process.unlisten(checkpoints)
        io.print("BEE_WINDOW_HOOKS_ACCEPTANCE: OK")
        return
    end

    local retained_home = false
    local continued_hook_submitted = false
    local continued_markers: {string} = {}
    local continuation_started = time.now():unix_nano()
    local continuation_screen = ""
    for _ = 1, 200 do
        local frame = view_two:snapshot()
        local screen = frame and table.concat(frame.rows) or ""
        continuation_screen = frame and table.concat(frame.rows, "\n") or ""
        collect_markers(continued_markers, screen)
        if screen:find("HOOK_HOME_SENTINEL:retained", 1, true) then retained_home = true end
        if screen:find("HOOK_TOOL:" .. accepted_result, 1, true) then continued_hook_submitted = true end
        if retained_home and continued_hook_submitted then break end
        time.sleep("50ms")
    end
    if not (retained_home and continued_hook_submitted) then
        local shown = continuation_screen:gsub("[ \t]+\n", "\n")
        error(string.format("%s after %d ms; continuation markers: [%s]\ncontinuation screen:\n%s\n%s",
            retained_home and "continuation hook was not accepted by real gateway (expected HOOK_TOOL:" .. accepted_result .. ")"
                or "continuation did not retain the session HOME sentinel",
            (time.now():unix_nano() - continuation_started) // 1000000, table.concat(continued_markers, " "),
            shown, placement_report()))
    end

    local total_hooks = 0
    local continuation_attempt_id: string? = nil
    local continuation_binding_id: string? = nil
    local continuation_session_id: string? = nil
    for _ = 1, 200 do
        local records = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64})
        local value = reply(records.value)
        total_hooks = 0
        continuation_attempt_id, continuation_binding_id, continuation_session_id = nil, nil, nil
        for _, item in ipairs(value.records :: {{[string]: unknown}}) do
            if item.kind == "observation" and item.action_id == admission.identities("window-hooks-req").action_id and type(item.body) == "table" then
                local body = item.body :: {[string]: unknown}
                if tostring(body.event_key or ""):find("^hook:") and type(body.data) == "table" then
                    local data = body.data :: {[string]: unknown}
                    local decoded = data.payload_json and json.decode(tostring(data.payload_json)) or nil
                    if type(decoded) == "table" then
                        local payload = decoded :: {[string]: unknown}
                        local fields = type(payload.fields) == "table" and payload.fields :: {[string]: unknown} or {}
                        total_hooks = total_hooks + 1
                        assert(payload.ambiguous == false, "fixture hook must remain unambiguous")
                        assert(fields.session_id == "s1", "hook provider conversation changed across continuation")
                        if item.attempt_id == previous_attempt_id then
                            assert(payload.binding_id == committed_binding_id, "initial hook binding changed in its own record")
                        else
                            continuation_attempt_id = tostring(item.attempt_id or "")
                            continuation_binding_id = tostring(payload.binding_id or "")
                            continuation_session_id = tostring(fields.session_id or "")
                        end
                    end
                end
            end
        end
        if total_hooks == 3 and continuation_attempt_id and continuation_attempt_id ~= ""
            and continuation_binding_id and continuation_binding_id ~= "" and continuation_session_id == "s1" then
            break
        end
        time.sleep("50ms")
    end
    assert(total_hooks == 3, "continuation must preserve the committed hooks and add only the new attempt hook")
    if pending_hook then
        -- The existing gateway contract rejects unclaimed rows on revocation.
        -- They remain durable rejections, never fabricated thread commits.
        local queue = reply(call("bee.gateway.binding:hook_queue", {binding_id = committed_binding_id}).value)
        local rejected = false
        for _, hook in ipairs(queue.hooks :: {{[string]: unknown}}) do
            local fields = reply(hook.fields)
            if fields.tool_use_id == "toolu_pending" then
                rejected = hook.status == "rejected" and type(hook.rejected_reason) == "string" and hook.rejected_reason ~= ""
            end
        end
        assert(rejected, "revoked unclaimed hook lost its durable rejection")
    end
    assert(continuation_attempt_id and continuation_attempt_id ~= previous_attempt_id, "continuation did not receive a fresh native attempt")
    assert(continuation_binding_id and continuation_binding_id ~= committed_binding_id, "continuation did not receive a fresh gateway binding")
    assert(continuation_session_id == "s1", "continuation did not preserve the provider conversation")
    local status_db = assert(store.open())
    local old_attempt = assert(store.attempt(status_db, previous_attempt_id), "previous placement attempt is missing")
    local new_attempt = assert(store.attempt(status_db, continuation_attempt_id), "continuation placement attempt is missing")
    status_db:release()
    assert(old_attempt.execution_state == "exited" and old_attempt.cleanup_state == "complete",
        "continuation did not complete cleanup of the previous execution")
    assert(type(old_attempt.session_ref) == "string" and old_attempt.session_ref == new_attempt.session_ref,
        "continuation changed the retained session identity")
    assert(old_attempt.action_id == new_attempt.action_id and old_attempt.owner_id == new_attempt.owner_id,
        "continuation changed the action or owner")

    assert(process.send(broker, "bee.app.request", {version = 1, request_id = "close-two", op = "close", workspace_id = WORKSPACE, id = continued.id}))
    local closed_two = false
    while not closed_two do
        local message = assert(replies:receive())
        local data = message:payload():data()
        if tostring(message:from()) == broker and type(data) == "table" and data.request_id == "close-two" and data.op == "close" then
            assert(data.error_code == "", "window continuation close failed: " .. tostring(data.error))
            closed_two = true
        end
    end
    assert(closed_two, "window continuation close failed")
    local continued_page = reply(call("bee.threads.service:read_after", {thread_id = THREAD, cursor = 0, limit = 64}).value)
    local continued_receipts = 0
    for _, item in ipairs(continued_page.records :: {{[string]: unknown}}) do
        if item.kind == "receipt" then
            continued_receipts = continued_receipts + 1
            local body = reply(item.body)
            local expected = crashed and item.attempt_id == previous_attempt_id and "uncertain" or "cancelled"
            assert(body.scope == "attempt" and body.outcome == expected, "unexpected continuation receipt outcome")
        end
    end
    assert(continued_receipts == 2, "expected one cancelled receipt per window attempt")

    -- 14. Teardown
    view_two:close()
    process.terminate(broker)
    process.unlisten(catalogs)
    process.unlisten(replies)
    process.unlisten(checkpoints)
    io.print("BEE_WINDOW_HOOKS_ACCEPTANCE: OK")
end

M.main = function() execute(false, false, false, false) end
M.run = M.main
M.crash = function() execute(true, false, false, false) end
M.cancel_recovery = function() execute(true, true, false, false) end
M.pending_hook = function() execute(true, false, true, false) end
M.command_hooks = function() execute(false, false, false, true) end

return M

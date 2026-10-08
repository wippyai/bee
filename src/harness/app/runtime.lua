-- MIT. Shared managed-window lifecycle for component-owned process entries.
--
-- The process entry supplies a constructor returning a process-local window. The broker grants
-- the terminal to that caller, so executor:terminal() runs in the actual app actor.
-- Gateway hooks are claimed, committed and acknowledged one future at a time.
local tty = require("tty")
local logger = require("logger")
local exec = require("exec")
local process = require("process")
local channel = require("channel")
local json = require("json")
local time = require("time")
local funcs = require("funcs")
local uuid = require("uuid")
local client = require("client")
local window_request = require("window_request")
local input_event = require("input_event")
local admission = require("admission")
local machine = require("machine")
local picker = require("picker")
local recovery = require("recovery")
local hooks = require("hooks")
local text = require("text")
local delivery = require("delivery")
local records = require("records")
local appearance = require("appearance")
local restore_view = require("restore_view")
local frame_ui = require("frame")
local bounds = require("bounds")
local placement_decode = require("placement_decode")

local THREADS = "bee.threads.binding"
type Fault = {code: string, message: string}
local function placement_target(admitted: admission.Admitted, method: string): string?
    return admitted.plan.placement_methods[method]
end

local function io(): machine.IO
    return {
        call = function(target: string, value: unknown): (unknown, string?)
            if target == "bee.placement.docker.binding:prepare" and type(value) == "table" then
                local request: {[string]: unknown} = {}
                for key, item in pairs(value) do request[key] = item end
                request.progress_recipient = tostring(process.pid())
                value = request
            end
            local reply, call_error = funcs.call(target, value)
            if call_error then return nil, tostring(call_error) end
            return reply, nil
        end,
        send = function(target: string, topic: string, value: unknown)
            process.send(target, topic, value)
        end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string
            local key, key_error = uuid.v7()
            if not key then error("allocate request key: " .. tostring(key_error)) end
            return key
        end,
    }
end

local function failure(reply: admission.Reply?): string
    if not reply then return "launch admission did not return a result" end
    local fault = reply.error
    if not fault then return "launch admission refused" end
    return fault.code .. ": " .. fault.message
end

local function call(target: string, value: unknown): (boolean, string?)
    local raw, call_error = funcs.call(target, value)
    if call_error then return false, tostring(call_error) end
    if type(raw) ~= "table" then return false, target .. " returned no reply" end
    local reply = raw
    if reply.ok ~= true then
        local fault = type(reply.error) == "table" and reply.error or {}
        return false, tostring(fault.code or "INTERNAL") .. ": " .. tostring(fault.message or "operation refused")
    end
    return true, nil
end

local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end

local function start_intent(intent: hooks.Intent): (funcs.Future?, string?)
    local future, err = funcs.async(intent.target, intent.request)
    if err then return nil, tostring(err) end
    return future, nil
end

-- A PTY only says the native UI completed. It never proves an agent turn
-- succeeded, so completion becomes an explicit uncertain receipt. An explicit
-- application close is the one case that truthfully records cancellation.
local function receipt(admitted: admission.Admitted, epoch: integer?, outcome: "cancelled" | "uncertain", reason: string,
    attempt_receipt: boolean): (boolean, string?)
    local code = outcome == "cancelled" and "native_window_closed" or "native_window_unobserved"
    local request: {[string]: unknown} = {thread_id = admitted.thread_id,
        idempotency_key = "launch:" .. admitted.attempt_id .. ":window:receipt",
        action_id = admitted.action_id,
        receipt = {scope = attempt_receipt and "attempt" or "action", outcome = outcome, evidence_refs = {}, error = {code = code, message = reason, retryable = false}}}
    if attempt_receipt then
        request.attempt_id = admitted.attempt_id
        request.idempotency_key = "launch:" .. admitted.attempt_id .. ":window:receipt"
        if epoch then request.carrier_epoch = epoch end
    end
    return call(THREADS .. ":receipt", request)
end

-- Failure before a native window exists still has durable work to close. A
-- claimed attempt uses an attempt receipt; an earlier failure settles the
-- admitted action when no attempt record was created. Gateway retirement and
-- receipts use the same owner paths as normal window shutdown.
local function settle_failure(admitted: admission.Admitted, epoch: integer?, reason: string, gateway_binding: string?, attempt_receipt: boolean, placement_attempt: boolean?): string
    local details: {string} = {}
    if placement_attempt then
        local stop_target = placement_target(admitted, "stop")
        local stopped = false
        local stop_error: string? = "selected placement binds no stop"
        if stop_target then stopped, stop_error = call(stop_target, {attempt_id = admitted.attempt_id}) end
        if not stopped then details[#details + 1] = "placement stop: " .. tostring(stop_error) end
        local cleanup_target = placement_target(admitted, "cleanup")
        local cleaned = false
        local cleanup_error: string? = "selected placement binds no cleanup"
        if cleanup_target then cleaned, cleanup_error = call(cleanup_target, {attempt_id = admitted.attempt_id}) end
        if not cleaned then details[#details + 1] = "placement cleanup: " .. tostring(cleanup_error) end
    end
    if gateway_binding then
        local revoked, revoke_error = call("bee.gateway.binding:revoke", {binding_id = gateway_binding})
        if not revoked then details[#details + 1] = "gateway revoke: " .. tostring(revoke_error) end
    end
    local settled, settlement_error = receipt(admitted, epoch, "uncertain", reason, attempt_receipt)
    if not settled then details[#details + 1] = "settlement: " .. tostring(settlement_error) end
    if #details == 0 then return reason end
    return reason .. " (" .. table.concat(details, "; ") .. ")"
end


local function persist_checkpoint(state: hooks.State, records: {{[string]: unknown}}?): (boolean, string?)
    local intent = hooks.next_intent(state, "launch:" .. state.attempt_id .. ":window:checkpoint", now_ms())
    if not intent then return false, "window checkpoint intent is missing" end
    if records then intent.request.records = records end
    if not hooks.begin(state, "checkpoint", intent) then return false, "window checkpoint is already in flight" end
    local raw, call_error = funcs.call(intent.target, intent.request)
    if call_error then
        hooks.lost(state, "checkpoint")
        return false, tostring(call_error)
    end
    local reply = hooks.decode(raw)
    if not reply then
        hooks.lost(state, "checkpoint")
        return false, "window checkpoint reply is unknown"
    end
    if not hooks.apply(state, "checkpoint", reply) then return false, "window checkpoint identity mismatch" end
    if not hooks.may_start(state) then return false, "window checkpoint did not persist" end
    return true, nil
end

local function drain_hooks(driver: delivery.Driver)
    local pending = delivery.advance(driver, now_ms())
    while not hooks.finished(driver.state) do
        local cases = {}
        if pending then cases[#cases + 1] = pending.response:case_receive() end
        local wait = math.max(1, delivery.due(driver) - now_ms())
        local timer = assert(time.timer(tostring(wait) .. "ms"))
        cases[#cases + 1] = timer:channel():case_receive()
        local selected = channel.select(cases)
        timer:stop()
        if pending and selected.channel == pending.response then
            delivery.complete(driver, pending, now_ms())
        end
        hooks.expire(driver.state, now_ms())
        if hooks.finished(driver.state) then break end
        pending = delivery.advance(driver, now_ms())
    end
    delivery.cancel(driver)
end

type Window = {
    send: (Window, tty.TTYEvent) -> (boolean, string?),
    done: (Window) -> exec.TerminalResultChannel,
    status: (Window) -> ("running" | "done", string?),
    close: (Window) -> (boolean, string?),
    finish: (Window) -> (boolean, string?),
}
type Open = (string, unknown) -> (Window?, string?)

-- The component-owned process supplies constructors keyed by placement binding.
-- Request data cannot supply executable callbacks or choose a constructor outside
-- the host-admitted placement plan.
local function main(value: unknown, constructors: {[string]: Open}, retained: boolean?, session_operation_key: string?)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local closes = assert(process.listen("bee.app.close", {message = true}))
    local checkpoint_results = assert(process.listen("bee.app.checkpoint_result", {message = true}))
    assert(tty.start())
    if launch.resume_schema ~= recovery.SCHEMA then
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        error("Managed window resume schema is unsupported")
    end
    local restoring = launch.resume_state ~= ""
    local selected = not restoring and (#launch.arguments == 0 or launch.arguments[1] == "--session")
    local direct = not restoring and #launch.arguments == 1 and launch.arguments[1]:sub(1, 1) ~= "{"
    local saved: recovery.Saved? = nil
    local admitted: admission.Admitted? = nil
    local ready_announced = false
    local phase_name = ""
    local phase_started = now_ms()
    local launch_records: {{[string]: unknown}} = {}
    local function record_phase(name: string)
        local at = now_ms()
        if phase_name ~= "" then
            launch_records[#launch_records + 1] = {source = "bee", body = {type = "extension",
                event_key = "startup:" .. launch.instance_id .. ":" .. tostring(#launch_records + 1),
                data = {type = "extension", event_name = "bee.carrier.startup", event_revision = "1",
                    payload_json = assert(json.encode({phase = phase_name, started_ms = phase_started, ended_ms = at}))}}}
        end
        phase_name, phase_started = name, at
    end
    local function phase(name: string)
        record_phase(name)
        local output = assert(tty.surface())
        local width, height = tty.screen_size()
        local frame = restore_view.draw(width, height, launch.appearance, name .. "…", "Starting Agent", "")
        assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
        assert(output:close())
    end
    local function show_failure(status: string, settle: (() -> string)?)
        logger:warn("Agent terminal did not start", {reason = status})
        local output = assert(tty.surface())
        local width, height = tty.screen_size()
        local preferences: appearance.Preferences = launch.appearance
        local states = assert(process.listen(appearance.TOPIC, {message = true}))
        local dirty = true
        local menu = frame_ui.menu()
        local dismissed = false
        local settlement = settle and channel.new(1) or nil
        local settlement_done = false
        if settle then
            local pending = assert(settlement)
            coroutine.spawn(function()
                pending:send(settle())
            end)
            status = status .. " · settlement pending; closing leaves its result unconfirmed"
        end
        local function render()
            if not dirty then return end
            local hint = settlement and not settlement_done and "Cleanup pending; Esc closes without waiting" or "Esc or Ctrl+Q closes"
            local frame = restore_view.draw(width, height, preferences, status, "Agent launch failed", hint)
            frame_ui.render(frame, menu, preferences)
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        if not ready_announced then
            client.ready(launch, {negotiate_close = true})
            ready_announced = true
        end
        while not dismissed do
            render()
            local cases = {input:case_receive(), lifecycle:case_receive(), closes:case_receive(), states:case_receive()}
            if settlement and not settlement_done then cases[#cases + 1] = settlement:case_receive() end
            local event = channel.select(cases)
            if not event.ok then
                dismissed = true
            elseif event.channel == lifecycle then
                if event.value.kind == process.event.CANCEL then dismissed = true end
            elseif event.channel == closes then
                local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
                if close then
                    client.close_reply(launch, close.request_id, {action = "accept"})
                    dismissed = true
                end
            elseif event.channel == states then
                if event.value:from() == launch.broker_pid then
                    local payload: unknown = event.value:payload():data()
                    local decoded = type(payload) == "table" and appearance.decode(payload.appearance) or nil
                    if decoded then
                        preferences = decoded
                        dirty = true
                    end
                end
            elseif settlement and not settlement_done and event.channel == settlement then
                status = tostring(event.value)
                settlement_done = true
                dirty = true
            else
                local data = input_event.decode(event.value)
                if data then
                    local routed, handled = frame_ui.route(menu, data)
                    if handled then dirty = true end
                    data = routed
                end
                if data then
                    if data.type == "close" then
                        dismissed = true
                    elseif data.type == "resize" or data.type == "start" then
                        width, height = data.width, data.height
                        dirty = true
                    elseif data.type == "key" and data.action == "press"
                        and (data.key_type == "escape" or data.key_type == "esc" or (data.ctrl and data.key == "q")) then
                        dismissed = true
                    end
                end
            end
        end
        process.unlisten(states)
        output:close()
    end
    local function show_login(notice: {code: "LOGIN_REQUIRED", provider: string, command: string}): boolean
        local output = assert(tty.surface())
        local width, height = tty.screen_size()
        local preferences = launch.appearance
        local states = assert(process.listen(appearance.TOPIC, {message = true}))
        local dirty = true
        local menu = frame_ui.menu()
        client.title(launch, notice.provider .. " · Login needed")
        while true do
            if dirty then
                local frame = restore_view.login(width, height, preferences, notice)
                frame_ui.render(frame, menu, preferences)
                assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
                dirty = false
            end
            local event = channel.select({input:case_receive(), lifecycle:case_receive(), closes:case_receive(), states:case_receive()})
            if not event.ok then break end
            if event.channel == lifecycle then
                if event.value.kind == process.event.CANCEL then break end
            elseif event.channel == closes then
                local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
                if close then
                    client.close_reply(launch, close.request_id, {action = "accept"})
                    break
                end
            elseif event.channel == states then
                if event.value:from() == launch.broker_pid then
                    local payload: unknown = event.value:payload():data()
                    local decoded = type(payload) == "table" and appearance.decode(payload.appearance) or nil
                    if decoded then
                        preferences = decoded
                        dirty = true
                    end
                end
            else
                local data = input_event.decode(event.value)
                if data then
                    local routed, handled = frame_ui.route(menu, data)
                    if handled then dirty = true end
                    data = routed
                end
                if data then
                    if data.type == "close" then break end
                    if data.type == "resize" or data.type == "start" then
                        width, height = data.width, data.height
                        dirty = true
                    elseif data.type == "key" and data.action == "press" then
                        if data.key_type == "enter" or data.key_type == "return" then
                            process.unlisten(states)
                            output:close()
                            return true
                        end
                        if data.key_type == "escape" or data.key_type == "esc" or (data.ctrl and data.key == "q") then break end
                    end
                end
            end
        end
        process.unlisten(states)
        output:close()
        return false
    end
    if not selected and not restoring then
        -- Resolution, setup, admission, preparation and the native open are
        -- durable work of unbounded length. Keep the broker's readiness
        -- deadline independent of it, as the restore path does: the surface
        -- is ready as soon as it says what it is doing.
        local output = assert(tty.surface())
        local width, height = tty.screen_size()
        local frame = restore_view.draw(width, height, appearance.defaults(), "Preparing the Agent launch…", "Starting Agent", "")
        assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
        client.ready(launch, {negotiate_close = true})
        ready_announced = true
        local output_closed, output_error = output:close()
        if not output_closed then
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            error("Managed window launch surface: " .. tostring(output_error))
        end
    end
    if selected then
        local choice, choice_error = picker.run(launch, input, lifecycle, closes)
        if not choice then
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            if choice_error then error(choice_error) end
            return
        end
        admitted = choice
    elseif restoring then
        local decoded, decode_error = json.decode(launch.resume_state)
        local restored, restore_error = recovery.decode(decoded)
        if not restored then
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            error("Managed window restore: " .. tostring(restore_error or decode_error))
        end
        saved = restored
        local request_id, request_error = uuid.v7()
        if not request_id then
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            error("Managed window restore request: " .. tostring(request_error))
        end

        local function recovery_request(id: string, digest: string, reauthorize: boolean): admission.Request
            local continuation: admission.Continuation = {origin_request_id = restored.origin_request_id,
                previous_attempt_id = restored.previous_attempt_id, thread_id = restored.thread_id, reauthorize = reauthorize}
            -- The continuation identity remains the checkpoint's identity. A
            -- changed plan is an explicit reauthorization of that identity,
            -- never a fresh conversation or an unbounded retry.
            return {request_id = id, definition_ref = restored.definition_ref, workspace_id = launch.workspace_id,
                brief = "", mode = "window", saved_profile_id = restored.saved_profile_id,
                saved_profile_revision = restored.saved_profile_revision, expected_plan_digest = digest,
                continuation = continuation, origin_view = {view_id = launch.view_id, instance_id = launch.instance_id}}
        end

        local request = recovery_request(request_id, restored.plan_digest, false)

        -- Admission may reconcile a dead native process and drain gateway
        -- hooks. Keep the broker's readiness deadline independent of that
        -- work: the surface is ready as soon as it can explain what it is
        -- doing and accept cancellation.
        local output = assert(tty.surface())
        local width, height = tty.screen_size()
        local preferences: appearance.Preferences = launch.appearance
        local status = "Restoring Agent…"
        local dirty = true
        local menu = frame_ui.menu()
        local cancelled = false
        local states = assert(process.listen(appearance.TOPIC, {message = true}))
        type Completion = {kind: "resolve" | "admission", serial: integer, plan: admission.Plan?, choice: admission.Admitted?,
            refused: admission.Reply?, admission_refusal: admission.Reply?}
        local completed = channel.new(1)
        local completed_pending: {[integer]: Completion} = {}
        local function send_completed(value: Completion)
            completed_pending[value.serial] = value
            completed:send(value.serial)
        end
        local phase: string = "initial"
        local operation: integer = 0

        local function render()
            if not dirty then return end
            local frame = restore_view.draw(width, height, preferences, status)
            frame_ui.render(frame, menu, preferences)
            assert(output:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local function cancel_restore()
            cancelled = true
            dirty = false
        end
        local function start_admission(candidate: admission.Request)
            operation = operation + 1
            local serial = operation
            phase = phase == "initial" and "initializing" or "admitting"
            coroutine.spawn(function()
                local choice: admission.Admitted? = nil
                local refused: admission.Reply? = nil
                local ok, unexpected = pcall(function()
                    choice, refused = admission.admit_request(candidate, session_operation_key)
                end)
                if not ok then refused = {ok = false, error = {code = "UNAVAILABLE", message = tostring(unexpected)}, value = nil} end
                -- A cancelled continuation may finish reconciliation after
                -- the UI has gone away. It never hands an admitted request to
                -- the native preparation path in that case.
                if cancelled or serial ~= operation then return end
                local sent: Completion = {kind = "admission", serial = serial, choice = choice, refused = refused}
                send_completed(sent)
            end)
        end
        local function start_resolve(refusal: admission.Reply?)
            operation = operation + 1
            local serial = operation
            phase = "resolving"
            status = refusal and "Checking the current launch plan…" or "Checking the saved launch plan…"
            dirty = true
            coroutine.spawn(function()
                local plan: admission.Plan? = nil
                local refused: admission.Reply? = nil
                local ok, unexpected = pcall(function()
                    plan, refused = admission.resolve(restored.definition_ref, "window", launch.workspace_id,
                        restored.saved_profile_id, restored.saved_profile_revision)
                end)
                if not ok then refused = {ok = false, error = {code = "UNAVAILABLE", message = tostring(unexpected)}, value = nil} end
                if cancelled or serial ~= operation then return end
                local sent: Completion = {kind = "resolve", serial = serial, plan = plan, refused = refused, admission_refusal = refusal}
                send_completed(sent)
            end)
        end

        render()
        client.ready(launch, {negotiate_close = true})
        ready_announced = true
        start_resolve(nil)

        while not admitted and not cancelled do
            render()
            local cases = {input:case_receive(), lifecycle:case_receive(), closes:case_receive(), states:case_receive(), completed:case_receive()}
            local event = channel.select(cases)
            if not event.ok then
                cancel_restore()
            elseif event.channel == lifecycle then
                if event.value.kind == process.event.CANCEL then cancel_restore() end
            elseif event.channel == closes then
                local close = client.close_request(launch, tostring(event.value:from()), event.value:payload():data())
                if close then
                    client.close_reply(launch, close.request_id, {action = "accept"})
                    cancel_restore()
                end
            elseif event.channel == states then
                if event.value:from() == launch.broker_pid then
                    local payload: unknown = event.value:payload():data()
                    local next_preferences = type(payload) == "table" and appearance.decode(payload.appearance) or nil
                    if next_preferences then
                        preferences = next_preferences
                        dirty = true
                    end
                end
            elseif event.channel == completed then
                local serial = event.value
                if type(serial) ~= "number" then error("invalid completion identity") end
                local result = assert(completed_pending[math.floor(serial)], "missing completion")
                completed_pending[math.floor(serial)] = nil
                if result.kind == "resolve" and result.serial == operation then
                    if result.plan then
                        -- A conflict that did not change the measured plan is
                        -- another admission refusal, not a reason to offer a
                        -- confirmation for an unchanged checkpoint.
                        if result.plan.plan_digest == request.expected_plan_digest then
                            if result.admission_refusal then
                                status = "Recovery admission refused: " .. failure(result.admission_refusal)
                                phase = "refused"
                            else
                                start_admission(request)
                            end
                        else
                            -- A changed plan is the one a new session of this
                            -- definition and saved profile is admitted under now;
                            -- the conversation resumes under it.
                            local reauthorized_id, id_error = uuid.v7()
                            if not reauthorized_id then
                                status = "Recovery admission refused: " .. tostring(id_error)
                                phase = "refused"
                            else
                                logger:info("Agent terminal resumes under its definition's current launch plan", {definition = request.definition_ref})
                                request = recovery_request(reauthorized_id, result.plan.plan_digest, true)
                                status = "Resuming under the current launch plan…"
                                start_admission(request)
                            end
                        end
                    else
                        status = "Current launch plan is unavailable: " .. failure(result.refused)
                        phase = "refused"
                    end
                    dirty = true
                elseif result.kind == "admission" and result.serial == operation then
                    if result.choice then
                        admitted = result.choice
                    elseif result.refused and result.refused.error
                        and result.refused.error.code == "CONFLICT" then
                        -- A plan that changed again while admitting is
                        -- resolved once more; an unchanged one is refused.
                        start_resolve(result.refused)
                    else
                        status = "Recovery admission refused: " .. failure(result.refused)
                        phase = "refused"
                    end
                    dirty = true
                end
                if phase == "refused" then
                    logger:warn("Agent terminal cannot resume", {reason = status, definition = request.definition_ref})
                end
            else
                local data = input_event.decode(event.value)
                if data then
                    local routed, handled = frame_ui.route(menu, data)
                    if handled then dirty = true end
                    data = routed
                end
                if data then
                    if data.type == "close" then
                        cancel_restore()
                    elseif data.type == "resize" or data.type == "start" then
                        width, height = data.width, data.height
                        dirty = true
                    elseif data.type == "key" and data.action == "press" then
                        if data.key_type == "escape" or data.key_type == "esc" or (data.ctrl and data.key == "q") then
                            cancel_restore()
                        end
                    end
                end
            end
        end
        process.unlisten(states)
        if not admitted then
            output:close()
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            return
        end
        local output_closed, output_error = output:close()
        if not output_closed then
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            error("Managed window recovery surface: " .. tostring(output_error))
        end
    elseif direct then
        local choice, direct_error = picker.direct(launch.workspace_id, launch.arguments[1], launch.thread_id,
            {view_id = launch.view_id, instance_id = launch.instance_id}, phase)
        if not choice then
            show_failure("Managed window admission: " .. tostring(direct_error))
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            return
        end
        admitted = choice
    else
        local body, body_error = window_request.decode(launch.arguments, launch.workspace_id, {view_id = launch.view_id, instance_id = launch.instance_id})
        if not body then
            show_failure("Invalid managed window launch: " .. tostring(body_error))
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            return
        end
        phase("Creating session and thread")
        local choice, admission_error = admission.admit_request(body, session_operation_key)
        if not choice then
            show_failure("Managed window admission: " .. failure(admission_error))
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            return
        end
        admitted = choice
    end
    if not admitted then tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results); return end
    local origin_request_id: string
    if saved then origin_request_id = saved.origin_request_id else origin_request_id = admitted.request_id end
    local application_saved: recovery.Saved = {definition_ref = admitted.plan.definition_ref,
        saved_profile_id = admitted.plan.saved_profile_id, saved_profile_revision = admitted.plan.saved_profile_revision,
        plan_digest = admitted.plan.plan_digest, origin_request_id = origin_request_id,
        previous_attempt_id = admitted.attempt_id, thread_id = admitted.thread_id}
    phase("Planning process")
    local transport = io()
    local prompt: string? = nil
    if admitted.session_ref then
        local raw, prompt_error = funcs.call("bee.threads.sessions.binding:launch_prompt", {session = admitted.session_ref})
        local reply = bounds.object(raw)
        local value = reply and reply.ok == true and bounds.object(reply.value) or nil
        if prompt_error or not value then
            local fault = reply and bounds.object(reply.error)
            show_failure("Managed window prompt: " .. tostring(prompt_error or (fault and fault.message) or "Sessions returned no prompt"))
            tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
            return
        end
        prompt = bounds.text(value.prompt, 65536)
    end
    local plan, plan_error = machine.plan(transport, admitted.request, prompt)
    if not plan then
        local reason = "Managed window plan: " .. tostring(plan_error)
        -- Planning precedes action admission, so there is no thread action
        -- to settle yet. Keep the diagnostic visible without manufacturing a
        -- lifecycle receipt for an identity that was never admitted.
        show_failure(reason)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    if plan.profile.mode ~= "window" or plan.profile.protocol ~= "pty" then
        local reason = "Managed window requires a PTY window profile"
        show_failure(reason)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    local open = constructors[plan.placement_binding.binding_id]
    if not open then
        show_failure("window component does not support the selected placement binding")
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    phase("Preparing process")
    local progress_events = assert(process.listen("bee.placement.image_progress", {message = true}))
    local completed = channel.new(1)
    type Preparation = {prepared: machine.PreparedAttempt?, error: string?, failed: machine.FailedPreparation?}
    local attempt_plan: machine.Plan = plan
    local finished: Preparation? = nil
    coroutine.spawn(function()
        local result, reason, failed = machine.prepare_attempt(transport, attempt_plan)
        finished = {prepared = result, error = reason, failed = failed}
        completed:send(true)
    end)
    local preparation: Preparation? = nil
    while preparation == nil do
        local selected_event = channel.select({progress_events:case_receive(), completed:case_receive()})
        if selected_event.channel == completed then
            preparation = finished
        elseif selected_event.channel == progress_events then
            local message = selected_event.value
            local data = placement_decode.preparation_progress(message:payload():data())
            if tostring(message:from()) == tostring(process.registry.lookup("bee.placement.docker/image")) and data
                and data.profile_ref == plan.request.placement_profile_ref then
                local surface = assert(tty.surface())
                local width, height = tty.screen_size()
                local frame = restore_view.draw(width, height, appearance.defaults(), data.detail, "Preparing Docker image", "")
                assert(surface:present(frame.rows, {cursor = {x = 1, y = 1, visible = false}}))
                surface:close()
            end
        end
    end
    process.unlisten(progress_events)
    local prepared, preparation_error, failed_preparation = preparation.prepared, preparation.error, preparation.failed
    if not prepared then
        local reason = "Managed window preparation: " .. tostring(preparation_error)
        local epoch = failed_preparation and failed_preparation.epoch
        local binding = failed_preparation and failed_preparation.gateway_binding
        local attempt = false
        if failed_preparation then attempt = failed_preparation.attempt end
        if failed_preparation then
            show_failure(reason, function(): string
                return settle_failure(admitted, epoch, reason, binding, attempt)
            end)
        else
            show_failure(reason)
        end
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    if prepared.notice then phase("Waiting for login-screen confirmation") end
    if prepared.notice and not show_login(prepared.notice) then
        settle_failure(admitted, prepared.epoch, "the login notice was closed before the provider started",
            prepared.gateway_binding, true, true)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    local gateway = plan.gateway
    local state = hooks.new({
        thread_id = admitted.thread_id,
        attempt_id = admitted.attempt_id,
        epoch = prepared.epoch,
        binding_ref = plan.binding.binding_id,
        binding_digest = plan.binding.binding_digest.entry,
        profile_id = plan.profile.id,
        profile_digest = plan.binding.profile_digest.entry,
        plan_digest = plan.plan_digest,
        session_ref = plan.request.session_ref,
        conversation_ref = plan.resume_ref,
        gateway_binding = prepared.gateway_binding,
        hooks_enabled = gateway ~= nil and #gateway.hooks > 0,
        drain_ms = plan.policy.drain_ms,
        decoder = records.batch,
    })
    local driver = delivery.new(state, start_intent, transport.key)
    phase("Saving launch checkpoint")
    local checkpointed, checkpoint_error = persist_checkpoint(state, launch_records)
    if not checkpointed then
        local reason = "native window checkpoint did not persist: " .. tostring(checkpoint_error)
        show_failure(reason, function(): string
            return settle_failure(admitted, prepared.epoch, reason, prepared.gateway_binding, true, true)
        end)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    phase("Attaching process output")
    local attach_target = machine.placement_target(plan, "attach")
    local attached = false
    local attachment_error: string? = "selected placement binds no attach"
    if attach_target then
        attached, attachment_error = call(attach_target, {
            attempt_id = admitted.attempt_id, recipient = process.pid(), generation = prepared.epoch,
        })
    end
    if not attached then
        local reason = "native placement attachment was not confirmed: " .. tostring(attachment_error)
        show_failure(reason, function(): string
            return settle_failure(admitted, prepared.epoch, reason, prepared.gateway_binding, true, true)
        end)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    local width, height = tty.screen_size()
    phase("Starting process")
    local terminal, terminal_error = open(admitted.attempt_id, {width = width, height = height,
        term = "xterm-256color", expected_binding = prepared.gateway_binding, expected_placement_binding = plan.placement_binding.binding_id,
        generation = prepared.epoch})
    if not terminal then
        local reason = "managed window did not open: " .. tostring(terminal_error)
        show_failure(reason, function(): string
            return settle_failure(admitted, prepared.epoch, reason, prepared.gateway_binding, true, true)
        end)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    record_phase("Recording supervised process start")
    local started, started_error = call(THREADS .. ":start_attempt", {thread_id = admitted.thread_id,
        idempotency_key = "launch:" .. admitted.attempt_id .. ":window:started", action_id = admitted.action_id,
        attempt_id = admitted.attempt_id, started = {execution_kind = "process", execution_ref = admitted.attempt_id,
            owner_epoch = transport.now_ms()}})
    if not started then
        terminal:close()
        terminal:done():receive()
        delivery.shutdown(driver, now_ms(), false)
        drain_hooks(driver)
        terminal:finish()
        local reason = "native window started but thread start was refused: " .. tostring(started_error)
        show_failure(reason, function(): string
            return settle_failure(admitted, prepared.epoch, reason, prepared.gateway_binding, true, true)
        end)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    record_phase("Running")
    local recorded, record_error = funcs.call(hooks.COMMIT, {thread_id = state.thread_id,
        idempotency_key = "launch:" .. state.attempt_id .. ":window:startup", attempt_id = state.attempt_id,
        carrier_epoch = state.epoch, expected_revision = state.revision, checkpoint = state.checkpoint, records = launch_records})
    local launch_receipt = not record_error and bounds.object(recorded)
    local revision = launch_receipt and launch_receipt.ok == true and bounds.object(launch_receipt.value)
    if not revision or revision.checkpoint_revision ~= state.revision + 1 then
        local reason = "Launch phase records did not persist: " .. tostring(record_error or "unexpected checkpoint revision")
        terminal:close()
        terminal:done():receive()
        terminal:finish()
        show_failure(reason, function(): string
            return settle_failure(admitted, prepared.epoch, reason, prepared.gateway_binding, true, true)
        end)
        tty.stop(); process.unlisten(closes); process.unlisten(checkpoint_results)
        return
    end
    state.revision = state.revision + 1
    local encoded, encode_error = recovery.encode(application_saved)
    local checkpoint_id: string? = nil
    local checkpoint_error: string? = encode_error
    if encoded and not retained then checkpoint_id, checkpoint_error = client.checkpoint(launch, encoded) end
    local checkpoint_deadline = now_ms() + 6000
    local published_activity: string? = nil
    local published_title: string? = nil
    local function publish_title()
        local suffix = prepared.notice and " · Login needed" or ""
        if published_activity then suffix = suffix .. " · " .. published_activity end
        if checkpoint_error then suffix = suffix .. " · Save unconfirmed" end
        local title = text.bound(admitted.plan.title, 77 - #suffix) .. suffix
        if title ~= published_title and client.title(launch, title) then published_title = title end
    end
    publish_title()
    if not selected and not ready_announced then client.ready(launch, {negotiate_close = true}) end

    local done = terminal:done()
    local closing = false
    local pending = delivery.advance(driver, now_ms())
    while true do
        local cases = {input:case_receive(), lifecycle:case_receive(), closes:case_receive(), done:case_receive(), checkpoint_results:case_receive()}
        if pending then cases[#cases + 1] = pending.response:case_receive() end
        local timer: time.Timer? = nil
        if (state.hooks_enabled and not hooks.finished(state)) or pending or checkpoint_id then
            local due = checkpoint_deadline
            if (state.hooks_enabled and not hooks.finished(state)) or pending then
                due = delivery.due(driver)
                if checkpoint_id then due = math.min(due, checkpoint_deadline) end
            end
            timer = assert(time.timer(tostring(math.max(1, due - now_ms())) .. "ms"))
            cases[#cases + 1] = timer:channel():case_receive()
        end
        local selected = channel.select(cases)
        if timer then timer:stop() end
        if checkpoint_id and now_ms() >= checkpoint_deadline then
            checkpoint_id = nil
            checkpoint_error = "application checkpoint acknowledgement timed out"
            publish_title()
        end
        if pending and selected.channel == pending.response then
            delivery.complete(driver, pending, now_ms())
            local activity = state.activity
            if activity then
                published_activity = activity
                publish_title()
            end
            pending = delivery.advance(driver, now_ms())
        elseif selected.channel == checkpoint_results and selected.ok then
            if checkpoint_id then
                local acknowledged, result_error = recovery.acknowledged(launch, tostring(selected.value:from()),
                    selected.value:payload():data(), checkpoint_id)
                if acknowledged or result_error then
                    checkpoint_id = nil
                    checkpoint_error = result_error
                    publish_title()
                end
            end
        elseif not selected.ok or selected.channel == done then
            break
        elseif selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then
                closing = true
                terminal:close()
                break
            end
        elseif selected.channel == closes then
            local close = client.close_request(launch, tostring(selected.value:from()), selected.value:payload():data())
            if close then
                closing = true
                terminal:close()
                client.close_reply(launch, close.request_id, {action = "accept"})
                break
            end
        elseif selected.channel == input then
            local event = input_event.decode(selected.value)
            if not event then
                -- An untrusted channel value is not terminal input.
            elseif event.type == "close" then
                closing = true
                terminal:close()
                break
            elseif event.type ~= "start" then
                local sent = terminal:send(event)
                if not sent then break end
            end
        else
            pending = delivery.advance(driver, now_ms())
        end
    end
    terminal:close()
    terminal:done():receive()
    delivery.shutdown(driver, now_ms(), closing)
    drain_hooks(driver)
    local finished, finish_error = terminal:finish()
    if not finished then error("Managed window finish: " .. tostring(finish_error)) end
    local outcome: "cancelled" | "uncertain" = hooks.outcome(state)
    local reason = outcome == "cancelled" and "the managed native window was closed" or "the managed native window completed without a logical turn result"
    if state.unresolved then reason = "the managed native window ended with unresolved hook delivery" end
    local settled, settlement_error = receipt(admitted, prepared.epoch, outcome,
        reason, true)
    if not settled then error("Managed window receipt: " .. tostring(settlement_error)) end
    if admitted.session_ref then
        local detached, detach_error = call("bee.threads.sessions.binding:detach", {session = admitted.session_ref,
            attempt_id = admitted.attempt_id, operation_key = "window-detach:" .. admitted.attempt_id})
        if not detached then error("Managed Session detach: " .. tostring(detach_error)) end
    end
    process.unlisten(closes)
    process.unlisten(checkpoint_results)
    tty.stop()
end

return {main = main}

-- MIT. One broker-granted terminal and one admitted native harness child.
--
-- An empty launch opens the host-defined profile picker; a measured envelope
-- selects one directly. Both use normal admission and carrier preparation.
-- The picker and native PTY share this actor's one broker terminal grant.
-- Gateway hooks are claimed, committed and acknowledged one future at a time.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local uuid = require("uuid")
local client = require("client")
local window_request = require("window_request")
local input_event = require("input_event")
local admission = require("admission")
local machine = require("machine")
local window = require("window")
local picker = require("picker")
local hooks = require("hooks")
local text = require("text")
local delivery = require("delivery")
local records = require("records")

local THREADS = "bee.threads.service"
type Fault = {code: string, message: string}

local function io(): machine.IO
    return {
        call = function(target: string, value: unknown): (unknown, string?)
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
    local reply = raw :: {[string]: unknown}
    if reply.ok ~= true then
        local fault = type(reply.error) == "table" and reply.error :: {[string]: unknown} or {}
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
local function receipt(admitted: admission.Admitted, epoch: integer, outcome: "cancelled" | "uncertain", reason: string): (boolean, string?)
    local code = outcome == "cancelled" and "native_window_closed" or "native_window_unobserved"
    return call(THREADS .. ":receipt", {thread_id = admitted.thread_id,
        idempotency_key = "launch:" .. admitted.attempt_id .. ":window:receipt",
        action_id = admitted.action_id, attempt_id = admitted.attempt_id, carrier_epoch = epoch,
        receipt = {scope = "attempt", outcome = outcome, evidence_refs = {}, error = {code = code, message = reason, retryable = false}}})
end

local function persist_checkpoint(state: hooks.State): (boolean, string?)
    local intent = hooks.next_intent(state, "launch:" .. state.attempt_id .. ":window:checkpoint", now_ms())
    if not intent then return false, "window checkpoint intent is missing" end
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

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid application launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local closes = assert(process.listen("bee.application.close", {message = true}))
    assert(tty.start())
    local selected = #launch.arguments == 0
    local admitted: admission.Admitted? = nil
    if selected then
        local choice, choice_error = picker.run(launch, input, lifecycle, closes)
        if not choice then
            tty.stop(); process.unlisten(closes)
            if choice_error then error(choice_error) end
            return
        end
        admitted = choice
    else
        local body, body_error = window_request.decode(launch.arguments, launch.workspace_id)
        if not body then tty.stop(); error("Invalid managed window launch: " .. tostring(body_error)) end
        local choice, admission_error = admission.admit_request(body)
        if not choice then tty.stop(); error("Managed window admission: " .. failure(admission_error)) end
        admitted = choice
    end
    if not admitted then tty.stop(); return end
    local transport = io()
    local plan, plan_error = machine.plan(transport, admitted.request)
    if not plan then
        tty.stop(); process.unlisten(closes)
        error("Managed window plan: " .. tostring(plan_error))
    end
    if plan.profile.mode ~= "window" or plan.profile.protocol ~= "pty" then
        tty.stop(); process.unlisten(closes)
        error("Managed window requires a PTY window profile")
    end
    local prepared, preparation_error = machine.prepare_attempt(transport, plan)
    if not prepared then
        tty.stop(); process.unlisten(closes)
        error("Managed window preparation: " .. tostring(preparation_error))
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
        gateway_binding = prepared.gateway_binding,
        hooks_enabled = gateway ~= nil and #gateway.hooks > 0,
        drain_ms = plan.policy.drain_ms,
        decoder = records.batch,
    })
    local driver = delivery.new(state, start_intent, transport.key)
    local checkpointed, checkpoint_error = persist_checkpoint(state)
    if not checkpointed then
        receipt(admitted, prepared.epoch, "uncertain", "native window checkpoint did not persist: " .. tostring(checkpoint_error))
        tty.stop(); process.unlisten(closes)
        error("Managed window checkpoint: " .. tostring(checkpoint_error))
    end
    local attached, attachment_error = call(machine.PLACEMENT .. ":attach", {
        attempt_id = admitted.attempt_id, recipient = process.pid(), generation = prepared.epoch,
    })
    if not attached then
        if prepared.gateway_binding then call(machine.GATEWAY .. ":revoke", {binding_id = prepared.gateway_binding}) end
        receipt(admitted, prepared.epoch, "uncertain", "native placement attachment was not confirmed: " .. tostring(attachment_error))
        tty.stop(); process.unlisten(closes)
        error("Managed window attachment: " .. tostring(attachment_error))
    end
    local width, height = tty.screen_size()
    local terminal, terminal_error = window.open(admitted.attempt_id, {width = width, height = height,
        term = "xterm-256color", expected_binding = prepared.gateway_binding})
    if not terminal then
        receipt(admitted, prepared.epoch, "uncertain", "native window did not open: " .. tostring(terminal_error))
        tty.stop(); process.unlisten(closes)
        error("Managed window open: " .. tostring(terminal_error))
    end
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
        receipt(admitted, prepared.epoch, "uncertain", "native window started but thread start was refused: " .. tostring(started_error))
        tty.stop(); process.unlisten(closes)
        error("Managed window thread start: " .. tostring(started_error))
    end
    if not selected then
        client.title(launch, text.bound(admitted.plan.title, 77))
        client.ready(launch, {negotiate_close = true})
    end

    local done = terminal:done()
    local published_activity: string? = nil
    local closing = false
    local pending = delivery.advance(driver, now_ms())
    while true do
        local cases = {input:case_receive(), lifecycle:case_receive(), closes:case_receive(), done:case_receive()}
        if pending then cases[#cases + 1] = pending.response:case_receive() end
        local timer: time.Timer? = nil
        if (state.hooks_enabled and not hooks.finished(state)) or pending then
            timer = assert(time.timer(tostring(math.max(1, delivery.due(driver) - now_ms())) .. "ms"))
            cases[#cases + 1] = timer:channel():case_receive()
        end
        local selected = channel.select(cases)
        if timer then timer:stop() end
        if pending and selected.channel == pending.response then
            delivery.complete(driver, pending, now_ms())
            local activity = state.activity
            if activity and activity ~= published_activity then
                local suffix = " · " .. activity
                local sent = client.title(launch, text.bound(admitted.plan.title, 77 - #suffix) .. suffix)
                if sent then published_activity = activity end
            end
            pending = delivery.advance(driver, now_ms())
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
        reason)
    if not settled then error("Managed window receipt: " .. tostring(settlement_error)) end
    process.unlisten(closes)
    tty.stop()
end

return {main = main}

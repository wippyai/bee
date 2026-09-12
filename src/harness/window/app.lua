-- MIT. One broker-granted terminal and one admitted native harness child.
--
-- An empty launch opens the host-defined profile picker; a measured envelope
-- selects one directly. Both use normal admission and carrier preparation.
-- The picker and native PTY share this actor's one broker terminal grant.
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
        terminal:finish()
        receipt(admitted, prepared.epoch, "uncertain", "native window started but thread start was refused: " .. tostring(started_error))
        tty.stop(); process.unlisten(closes)
        error("Managed window thread start: " .. tostring(started_error))
    end
    if not selected then
        client.title(launch, admitted.plan.launch_id)
        client.ready(launch, {negotiate_close = true})
    end

    local done = terminal:done()
    local closing = false
    while true do
        local selected = channel.select({input:case_receive(), lifecycle:case_receive(), closes:case_receive(), done:case_receive()})
        if not selected.ok or selected.channel == done then break end
        if selected.channel == lifecycle then
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
        end
    end
    terminal:close()
    terminal:done():receive()
    local finished, finish_error = terminal:finish()
    if not finished then error("Managed window finish: " .. tostring(finish_error)) end
    local outcome: "cancelled" | "uncertain" = closing and "cancelled" or "uncertain"
    local settled, settlement_error = receipt(admitted, prepared.epoch, outcome,
        closing and "the managed native window was closed" or "the managed native window completed without a logical turn result")
    if not settled then error("Managed window receipt: " .. tostring(settlement_error)) end
    process.unlisten(closes)
    tty.stop()
end

return {main = main}

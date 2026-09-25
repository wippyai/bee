-- MIT. The production carrier process: real IO, no hooks. Arguments name
-- the attempt and its request; the process plans, opens or resumes, pumps
-- output into thread records, settles, closes, and returns the settlement.
local process = require("process")
local channel = require("channel")
local time = require("time")
local funcs = require("funcs")
local uuid = require("uuid")
local machine = require("machine")
local placement_protocol = require("placement_protocol")
local lease = require("lease")
type Mode = "open" | "resume"
local function io_for(after: ((string) -> ())?): machine.IO
    return {
        call = function(target: string, request: unknown): (unknown, string?)
            local result, err = funcs.call(target, request)
            if err then return nil, tostring(err) end
            return result, nil
        end,
        send = function(pid: string, topic: string, payload: unknown)
            process.send(pid, topic, payload)
        end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string
            local id, err = uuid.v7()
            if err or not id then error("uuid: " .. tostring(err)) end
            return id
        end,
        after = after,
    }
end
local TOPIC_INPUT = "bee.carrier.input"
-- run drives one attempt; the test harness passes hooks, production none.
-- controller is the only process whose input requests are honoured.
local function drive(request: machine.Request, mode: Mode, controller: string?, after: ((string) -> ())?): {[string]: unknown}
    local io = io_for(after)
    -- Subscriptions come first: the runner announces itself and may emit
    -- output the moment placement starts it.
    local outputs = assert(process.listen(placement_protocol.TOPIC_OUTPUT, {message = true}))
    local exits = assert(process.listen(placement_protocol.TOPIC_EXIT, {message = true}))
    local acks = assert(process.listen(placement_protocol.TOPIC_ACK, {message = true}))
    local inputs = assert(process.listen(TOPIC_INPUT, {message = true}))
    local attached = assert(process.listen(placement_protocol.TOPIC_ATTACHED, {message = true}))
    local statuses = assert(process.listen(placement_protocol.TOPIC_WRITE_STATUS, {message = true}))
    local events = assert(process.events())
    local plan, plan_error = machine.plan(io, request)
    if not plan then error("plan: " .. tostring(plan_error)) end
    local session: machine.Session?
    local open_error: string?
    if mode == "resume" then session, open_error = machine.resume(io, plan) else session, open_error = machine.open(io, plan) end
    if not session then error(mode .. ": " .. tostring(open_error)) end
    if mode == "resume" then
        local reconciled, reconcile_error = machine.reconcile_writes(io, session)
        if not reconciled then error("reconcile writes: " .. tostring(reconcile_error)) end
    end
    local function advance(poll: boolean)
        local ok, err = machine.advance_permissions(io, session, poll)
        if not ok then error("permission: " .. tostring(err)) end
    end
    advance(false)
    local push_enabled = plan.policy.inbox_push == true
    local poll_ms = 0
    if plan.exchange then poll_ms = plan.exchange.poll_ms end
    if push_enabled and poll_ms == 0 then poll_ms = 500 end
    local poll_timer = time.ticker(tostring(math.max(poll_ms, 50)) .. "ms")
    -- Wakeup hints: a private topic registered with the thread waiter, and
    -- the approval-transition subscription paged on every wake or tick.
    local hints_topic = "bee.carrier.hints." .. process.pid()
    local hints = assert(process.listen(hints_topic, {message = true}))
    local waiter_id = io.key()
    local hint_after = 0
    local registered_until = 0
    local pending_offer: machine.Offer? = nil
    local function register_hints()
        local pid, lookup_error = process.registry.lookup(machine.WAITER_NAME)
        if lookup_error or not pid then return end
        local deadline = io.now_ms() + machine.HINT_REGISTRATION_MS
        process.send(tostring(pid), "bee.threads.wait.register", {version = 1, waiter_id = waiter_id, topic = hints_topic, thread_id = request.thread_id, after_sequence = hint_after, deadline_at = deadline})
        registered_until = deadline
    end
    local function unregister_hints()
        local pid, lookup_error = process.registry.lookup(machine.WAITER_NAME)
        if lookup_error or not pid then return end
        process.send(tostring(pid), "bee.threads.wait.unregister", {version = 1, waiter_id = waiter_id})
    end
    -- One coalesced refresh: page the hints, read the owner when a hint or
    -- the tick asks for it, then acknowledge the page.
    local function refresh(poll: boolean)
        local hinted, after = machine.take_hints(io, session)
        if hinted or poll then advance(true) end
        if push_enabled then
            local offered, offer_error = machine.offer_inbox(io, session)
            if offer_error then error("inbox offer: " .. offer_error) end
            if offered and offered.state == "offered" and pending_offer and pending_offer.record_id == offered.record_id and pending_offer.dispatch then
                offered.dispatch = true
            end
            pending_offer = offered
        end
        machine.acknowledge_hints(io, session)
        if after then hint_after = after end
        if poll and not session.checkpoint.hint_subscription and (plan.exchange or push_enabled) then
            local opened = machine.open_hints(io, session)
            if opened then hint_after = opened end
        end
        register_hints()
    end
    if plan.exchange or push_enabled then
        local opened, hints_error = machine.open_hints(io, session)
        if hints_error then error("hints: " .. tostring(hints_error)) end
        if opened then hint_after = opened end
        refresh(true)
    end
    -- Hook intake: the gateway's queue for this binding is drained on a
    -- tick and on every wake; nothing it holds decides anything.
    local hooks_ticker = time.ticker("1000ms")
    local hooking = plan.gateway ~= nil and #(plan.gateway :: {hooks: {string}}).hooks > 0 and session.checkpoint.gateway_binding ~= nil
    local function drain_hooks()
        if not hooking then return end
        local _, hooks_error = machine.drain_hooks(io, session)
        if hooks_error then error("hooks: " .. tostring(hooks_error)) end
    end
    drain_hooks()
    local drain_timer = time.after("1ms")
    local draining = false
    local drain_elapsed = false
    if session.exit then
        draining = true
        drain_timer = time.after(tostring(plan.policy.runner_drain_ms + plan.policy.drain_ms) .. "ms")
    end
    local settlement: unknown = nil
    local queued: {{write_id: string, data: string}} = {}
    local function flush_queued()
        if not session.runner then return end
        local pending = queued
        queued = {}
        for _, item in ipairs(pending) do
            local ok, err = machine.write(io, session, item.write_id, item.data)
            if not ok then error("write: " .. tostring(err)) end
        end
    end
    -- The declared session end runs once the outcome is decided and before
    -- the settlement records end the attempt: close stdin where the launch
    -- declared it, the cooperative stop as the fallback, the runner's kill
    -- after its grace. Any other live child is stopped after settlement.
    local ended = false
    local function await_exit()
        local grace = time.after(tostring(plan.policy.stop_grace_ms + plan.policy.runner_drain_ms + plan.policy.drain_ms) .. "ms")
        while not session.exit do
            local selected = channel.select({exits:case_receive(), grace:case_receive()})
            if not selected.ok or selected.channel == grace then break end
            local message = selected.value
            machine.on_exit(io, session, tostring(message:from()), message:payload():data() :: placement_protocol.Exit)
        end
    end
    local function end_session(record: boolean)
        if ended then return end
        ended = true
        local ending, end_error = machine.end_session(io, session, record)
        if end_error then error("end session: " .. tostring(end_error)) end
        if ending ~= "none" then await_exit() end
        if ending == "closed" and not session.exit then
            local stopping, stop_error = machine.stop_session(io, session)
            if stop_error then error("stop after close: " .. tostring(stop_error)) end
            if stopping ~= "none" then await_exit() end
        end
    end
    while true do
        local cases = {outputs:case_receive(), exits:case_receive(), acks:case_receive(), inputs:case_receive(), attached:case_receive(), statuses:case_receive(), events:case_receive()}
        if draining and not drain_elapsed then cases[#cases + 1] = drain_timer:case_receive() end
        if poll_ms > 0 then
            cases[#cases + 1] = poll_timer:channel():case_receive()
            cases[#cases + 1] = hints:case_receive()
        end
        if hooking then cases[#cases + 1] = hooks_ticker:channel():case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if hooking and selected.channel == hooks_ticker:channel() then drain_hooks() end
        if selected.channel == outputs then
            local message = selected.value
            local data = message:payload():data() :: placement_protocol.Output
            local ok, err = machine.on_output(io, session, tostring(message:from()), data)
            if not ok then error("output: " .. tostring(err)) end
        elseif selected.channel == exits then
            local message = selected.value
            local data = message:payload():data() :: placement_protocol.Exit
            machine.on_exit(io, session, tostring(message:from()), data)
            if not draining then
                draining = true
                drain_timer = time.after(tostring(plan.policy.runner_drain_ms + plan.policy.drain_ms) .. "ms")
            end
        elseif selected.channel == acks then
            local message = selected.value
            local data = message:payload():data() :: placement_protocol.InputAck
            local ok, err = machine.on_write_ack(io, session, tostring(message:from()), data)
            if not ok then error("write ack: " .. tostring(err)) end
        elseif selected.channel == attached then
            local message = selected.value
            local data = message:payload():data() :: placement_protocol.Attached
            if machine.on_attached(session, tostring(message:from()), data) then
                local ok, err = machine.reconcile_writes(io, session)
                if not ok then error("reconcile writes: " .. tostring(err)) end
                flush_queued()
                advance(false)
            end
        elseif selected.channel == statuses then
            local message = selected.value
            local data = message:payload():data() :: placement_protocol.WriteStatus
            local ok, err = machine.on_write_status(io, session, tostring(message:from()), data)
            if not ok then error("write status: " .. tostring(err)) end
        elseif selected.channel == inputs then
            local message = selected.value
            local data = message:payload():data()
            if controller and tostring(message:from()) == controller and type(data) == "table" and type(data.write_id) == "string" and type(data.data) == "string" then
                queued[#queued + 1] = {write_id = data.write_id :: string, data = data.data :: string}
                flush_queued()
            end
        elseif draining and selected.channel == drain_timer then
            drain_elapsed = true
        elseif poll_ms > 0 and selected.channel == poll_timer:channel() then
            refresh(true)
            if push_enabled and #session.checkpoint.pending_writes > 0 then
                local reconciled, reconcile_error = machine.reconcile_writes(io, session)
                if not reconciled then error("inbox write status: " .. tostring(reconcile_error)) end
            end
        elseif poll_ms > 0 and selected.channel == hints then
            refresh(false)
        elseif selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        end
        if selected.channel ~= poll_timer:channel() and selected.channel ~= hints then advance(false) end
        if push_enabled and not session.exit then
            local finished, finish_error = machine.finish_push_turn(io, session)
            if finish_error then error("push turn: " .. finish_error) end
            if finished then refresh(true) end
            if not session.turn_open and pending_offer and pending_offer.dispatch then
                local write_id, push_error = machine.begin_push_turn(io, session, pending_offer)
                if not write_id then error("push dispatch: " .. tostring(push_error)) end
                pending_offer.dispatch = false
            end
        end
        if not push_enabled and plan.launch.session_end == "stdin_close" and not session.exit and session.runner and not ended and machine.ready_to_settle(session, drain_elapsed) then
            -- Every exchange is closed on record before input closes.
            local closed_all, close_error = machine.close_exchanges(io, session, drain_elapsed)
            if close_error then error("close exchanges: " .. tostring(close_error)) end
            if closed_all then end_session(true) end
        end
        local push_waiting = push_enabled and not session.exit and (not session.terminal or session.terminal.outcome == "succeeded")
        local decision: unknown = nil
        local settle_error: string? = nil
        if not push_waiting then decision, settle_error = machine.settle(io, session, drain_elapsed) end
        if settle_error then error("settle: " .. tostring(settle_error)) end
        if decision then
            settlement = decision
            break
        end
    end
    if settlement then end_session(false) end
    process.unlisten(outputs)
    process.unlisten(exits)
    process.unlisten(acks)
    process.unlisten(inputs)
    process.unlisten(attached)
    process.unlisten(statuses)
    poll_timer:stop()
    hooks_ticker:stop()
    if plan.exchange or push_enabled then
        machine.close_hints(io, session)
        unregister_hints()
    end
    process.unlisten(hints)
    local attempt = machine.close(io, session)
    return {settlement = settlement, placement = attempt, epoch = session.epoch, revision = session.revision}
end
-- The run keeps its workspace's host serving until it ends, whichever way.
local function run(request: machine.Request, mode: Mode, controller: string?, after: ((string) -> ())?): {[string]: unknown}
    local held, refused = lease.hold(request.workspace_id)
    if refused then error("workspace host lease: " .. refused) end
    local ok, result = pcall(drive, request, mode, controller, after)
    if held then lease.release(held) end
    if not ok then error(result) end
    return result
end
local function main(request: machine.Request, mode: string, controller: string?): {[string]: unknown}
    local chosen: Mode = "open"
    if mode == "resume" then chosen = "resume" end
    return run(request, chosen, controller, nil)
end
return {main = main, run = run}

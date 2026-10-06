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
local eventbus = require("events")
local commits = require("commits")
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
    local states = assert(process.listen(placement_protocol.TOPIC_STARTED, {message = true}))
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
    if session.runner then assert(process.monitor(session.runner)) end
    if mode == "resume" then
        local reconciled, reconcile_error = machine.reconcile_writes(io, session)
        if not reconciled then error("reconcile writes: " .. tostring(reconcile_error)) end
    end
    local function advance(poll: boolean)
        local ok, err = machine.advance_permissions(io, session, poll)
        if not ok then error("permission: " .. tostring(err)) end
    end
    advance(false)
    local poll_ms = 0
    if plan.exchange then poll_ms = plan.exchange.poll_ms end
    local poll_timer = time.ticker(tostring(math.max(poll_ms, 50)) .. "ms")
    -- Wakeup hints: a commit on the thread, announced by the Threads
    -- service, pages the approval-transition subscription. The carrier hears
    -- commits before it first pages, so a transition committed after any
    -- page wakes it.
    local hints = plan.exchange and assert(eventbus.subscribe(commits.system(request.thread_id), commits.KIND)) or nil
    -- One coalesced refresh: page the hints, read the owner when a hint or
    -- the tick asks for it, then acknowledge the page.
    local function refresh(poll: boolean)
        local hinted, hints_error = machine.take_hints(io, session)
        if hints_error then error("hints: " .. hints_error) end
        if hinted or poll then advance(true) end
        local _, acknowledgment_error = machine.acknowledge_hints(io, session)
        if acknowledgment_error then error("hints: " .. acknowledgment_error) end
        if poll and not session.checkpoint.hint_subscription and plan.exchange then machine.open_hints(io, session) end
    end
    if plan.exchange then
        local hints_error = machine.open_hints(io, session)
        if hints_error then error("hints: " .. tostring(hints_error)) end
        refresh(true)
    end
    -- Hook intake: the gateway's queue for this binding is drained on a
    -- tick and on every wake; nothing it holds decides anything.
    local hooks_ticker = time.ticker("1000ms")
    local hooking = plan.gateway ~= nil and #(plan.gateway).hooks > 0 and session.checkpoint.gateway_binding ~= nil
    local function drain_hooks()
        if not hooking then return end
        local _, hooks_error = machine.drain_hooks(io, session)
        if hooks_error then error("hooks: " .. tostring(hooks_error)) end
    end
    drain_hooks()
    local drain_elapsed = session.runner == nil
    local settlement: unknown = nil
    local queued: {{write_id: string, data: string}} = {}
    local function flush_queued()
        if not session.runner or session.placement_state == "starting" then return end
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
    local close_grace: Channel<time.Time>? = nil
    local function end_session(record: boolean)
        if ended then return end
        ended = true
        local ending, end_error = machine.end_session(io, session, record)
        if end_error then error("end session: " .. tostring(end_error)) end
        if ending == "closed" and not session.exit then
            close_grace = time.after(tostring(plan.policy.stop_grace_ms) .. "ms")
        end
    end
    while true do
        local cases = {states:case_receive(), outputs:case_receive(), exits:case_receive(), acks:case_receive(), inputs:case_receive(), attached:case_receive(), statuses:case_receive(), events:case_receive()}
        if close_grace then cases[#cases + 1] = close_grace:case_receive() end
        if hints then
            cases[#cases + 1] = poll_timer:channel():case_receive()
            cases[#cases + 1] = hints:channel():case_receive()
        end
        if hooking then cases[#cases + 1] = hooks_ticker:channel():case_receive() end
        -- A supervised EXIT seals delivery; consume its queued messages before settlement.
        local selected
        if session.runner_ended or session.settled or (session.exit and not session.runner) then
            selected = channel.select({states:case_receive(), outputs:case_receive(), exits:case_receive(), acks:case_receive(),
                attached:case_receive(), statuses:case_receive(), default = true})
            if selected.default then
                if session.placement_state == "starting" then
                    -- The startup owner publishes the refusal after it observes
                    -- runner EXIT. Await that state event before classifying it.
                    selected = channel.select(cases)
                else drain_elapsed = true end
            end
        else
            selected = channel.select(cases)
        end
        if not selected.ok and not selected.default then break end
        if selected.channel == states then
            local message = selected.value
            local hint = placement_protocol.decode_state_hint(message:payload():data())
            if hint and hint.attempt_id == request.attempt_id and hint.generation == session.epoch then
                local ok, err = machine.on_startup(io, session)
                if not ok then error("startup state: " .. tostring(err)) end
                flush_queued()
            end
        elseif selected.channel == outputs then
            if session.placement_state == "starting" then
                local ok, err = machine.on_startup(io, session)
                if not ok then error("startup state before output: " .. tostring(err)) end
            end
            local message = selected.value
            local data = placement_protocol.decode_output(message:payload():data())
            if data then
                local ok, err = machine.on_output(io, session, tostring(message:from()), data)
                if not ok then error("output: " .. tostring(err)) end
            end
        elseif selected.channel == exits then
            local message = selected.value
            local data = placement_protocol.decode_exit(message:payload():data())
            if data then
                machine.on_exit(io, session, tostring(message:from()), data)
            end
        elseif selected.channel == acks then
            local message = selected.value
            local data = placement_protocol.decode_input_ack(message:payload():data())
            if data then
                local ok, err = machine.on_write_ack(io, session, tostring(message:from()), data)
                if not ok then error("write ack: " .. tostring(err)) end
            end
        elseif selected.channel == attached then
            local message = selected.value
            local data = message:payload():data()
            if machine.on_attached(session, tostring(message:from()), data) then
                local ok, err = machine.reconcile_writes(io, session)
                if not ok then error("reconcile writes: " .. tostring(err)) end
                flush_queued()
                advance(false)
            end
        elseif selected.channel == statuses then
            local message = selected.value
            local data = placement_protocol.decode_write_status(message:payload():data())
            if data then
                local ok, err = machine.on_write_status(io, session, tostring(message:from()), data)
                if not ok then error("write status: " .. tostring(err)) end
            end
        elseif selected.channel == inputs then
            local message = selected.value
            local data = message:payload():data()
            if controller and tostring(message:from()) == controller and type(data) == "table" and type(data.write_id) == "string" and type(data.data) == "string" then
                queued[#queued + 1] = {write_id = data.write_id, data = data.data}
                flush_queued()
            end
        elseif close_grace and selected.channel == close_grace then
            close_grace = nil
            local queued_exit = channel.select({exits:case_receive(), default = true})
            if not queued_exit.default and queued_exit.ok then
                local message = queued_exit.value
                local data = placement_protocol.decode_exit(message:payload():data())
                if data then machine.on_exit(io, session, tostring(message:from()), data) end
            end
            if not session.exit then
                local _, stop_error = machine.stop_session(io, session)
                if stop_error then error("stdin-close grace elapsed before exit: " .. tostring(stop_error)) end
            end
        elseif hints and selected.channel == poll_timer:channel() then
            refresh(true)
        elseif hints and selected.channel == hints:channel() then
            -- Commits announced meanwhile are covered by this one page.
            local queued_commit = channel.select({hints:channel():case_receive(), default = true})
            while queued_commit.ok and not queued_commit.default do queued_commit = channel.select({hints:channel():case_receive(), default = true}) end
            refresh(false)
        elseif selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
            if selected.value.kind == process.event.EXIT then machine.on_runner_exit(session, tostring(selected.value.from)) end
        end
        if selected.channel ~= poll_timer:channel() and not (hints and selected.channel == hints:channel()) then advance(false) end
        drain_hooks()
        if not ended and not session.terminal then
            for _, permission in ipairs(session.checkpoint.permissions) do
                if permission.phase == "closed" then end_session(false); break end
            end
        end
        if plan.launch.session_end == "stdin_close" and not session.exit and session.runner and not ended and machine.ready_to_settle(session, drain_elapsed) then
            -- Every exchange is closed on record before input closes.
            local closed_all, close_error = machine.close_exchanges(io, session, drain_elapsed)
            if close_error then error("close exchanges: " .. tostring(close_error)) end
            if closed_all then end_session(true) end
        end
        local decision: unknown = nil
        local settle_error: string? = nil
        local output_pending = session.runner ~= nil and not drain_elapsed
            and (not machine.drained(session) or not session.exit)
        if output_pending then
            if not ended and machine.ready_to_settle(session, drain_elapsed) then end_session(false) end
        else
            decision, settle_error = machine.settle(io, session, drain_elapsed)
        end
        if settle_error then error("settle: " .. tostring(settle_error)) end
        if decision then
            settlement = decision
            break
        end
    end
    if settlement then end_session(false) end
    if session.runner then process.unmonitor(session.runner) end
    process.unlisten(outputs)
    process.unlisten(exits)
    process.unlisten(acks)
    process.unlisten(inputs)
    process.unlisten(attached)
    process.unlisten(statuses)
    poll_timer:stop()
    hooks_ticker:stop()
    if hints then
        machine.close_hints(io, session)
        hints:close()
    end
    process.unlisten(states)
    local attempt = machine.close(io, session)
    return {settlement = settlement, placement = attempt, epoch = session.epoch, revision = session.revision}
end
local function run(request: machine.Request, mode: Mode, controller: string?, after: ((string) -> ())?): {[string]: unknown}
    return drive(request, mode, controller, after)
end
local function main(request: machine.Request, mode: string, controller: string?): {[string]: unknown}
    local chosen: Mode = "open"
    if mode == "resume" then chosen = "resume" end
    local name = machine.CARRIER_REGISTRY_PREFIX .. request.attempt_id
    local registered, register_error = process.registry.register(name)
    if not registered then error("register carrier: " .. tostring(register_error)) end
    local ok, result = pcall(run, request, chosen, controller, nil)
    local _, unregister_error = process.registry.unregister(name)
    if not ok then error(result) end
    if unregister_error then error("unregister carrier: " .. tostring(unregister_error)) end
    return result
end
return {main = main, run = run}

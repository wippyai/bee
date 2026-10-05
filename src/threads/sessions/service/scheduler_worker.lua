-- MIT. The scheduler process performs an immediate boot scan and a bounded
-- periodic pull; wake messages only shorten the delay.
local process = require("process")
local time = require("time")
local channel = require("channel")
local logger = require("logger")
local funcs = require("funcs")
local bounds = require("bounds")
local scheduler = require("scheduler")
local threads_journal = require("threads_journal")
local executors = require("executors")
local lifecycle = require("lifecycle")
local M = {}
M.WORKER = "bee.sessions.scheduler"
M.TOPIC_WAKE = "bee.sessions.scheduler.wake"
M.SCAN_INTERVAL = "5s"

local function pass(only_work: string?): (string?, boolean)
    local runtime, runtime_error = executors.runtime()
    if not runtime then return runtime_error or "executor registry is unavailable", false end
    local run_id = scheduler.run_identity()
    if not run_id then return "scheduler identity unavailable", false end
    local service, service_error = scheduler.create(threads_journal.adapter(), runtime, nil, run_id)
    if not service then return service_error or "scheduler could not be initialized", false end
    local report, pass_error = service.run_pass(only_work)
    if not report then return pass_error or "scheduler scan failed", false end
    for _, issue in ipairs(report.issues) do
        logger:error("Session scheduler work pass failed", {work = issue.work or "", stage = issue.stage, cause = issue.reason})
    end
    if report.uncertain > 0 then
        logger:error("Session executor reconciliation is uncertain", {count = report.uncertain})
    end
    if report.uncertain > 0 then return "Session executor reconciliation remains uncertain", true end
    return nil, scheduler.progressed(report)
end


local function turn_run(request: unknown): unknown
    local input = bounds.object(request)
    local work = input and bounds.id(input.work)
    if not work or bounds.fields(input, {"work"}) then return {ok = false, error = "invalid scheduled work"} end
    local err, progressed = pass(work)
    return {ok = err == nil, error = err, progressed = progressed}
end

type Pending = {work: string, future: funcs.Future, response: Channel<unknown>}
local function main()
    local events = assert(process.events())
    local hints = assert(process.listen(M.TOPIC_WAKE, {message = true}))
    local lifecycle_inbox = assert(process.listen(lifecycle.TOPIC, {message = true}))
    local definition = assert(lifecycle.definition(), "scheduler definition could not be captured")
    local waiting: {recipient: string, topic: string, request: lifecycle.Request}? = nil
    local drain_error: string? = nil
    local ticker = time.ticker(M.SCAN_INTERVAL)
    local active: {[string]: Pending} = {}
    -- Work whose last pass changed nothing waits for a commit hint or the
    -- periodic scan, so a turn still running is not passed over in a loop.
    local settled_until_wake: {[string]: boolean} = {}
    local function scan()
        if waiting or lifecycle.fenced() then return end
        local page, scan_error = threads_journal.invoke("work_scan", {limit = scheduler.MAX_SCAN})
        local decoded = bounds.object(page)
        local rows = decoded and bounds.array(decoded.items, scheduler.MAX_SCAN)
        if scan_error or not rows then logger:error("Session scheduler scan failed", {cause = scan_error or "malformed work page"}); return end
        for _, raw in ipairs(rows) do
            local due = bounds.object(raw)
            local session, work = due and bounds.id(due.session), due and bounds.id(due.work)
            if session and work and not active[session] and not settled_until_wake[work] and scheduler.activates(due) then
                local future, start_error = funcs.async("bee.threads.sessions.service:turn_run", {work = work})
                if future then active[session] = {work = work, future = future, response = future:response()}
                else logger:error("Session scheduler activation failed", {work = work, cause = tostring(start_error)}) end
            end
        end
    end
    local registered, register_error = process.registry.register(M.WORKER)
    if not registered then error("register session scheduler: " .. tostring(register_error)) end
    scan()
    while true do
        local cases = {events:case_receive(), hints:case_receive(), ticker:channel():case_receive(), lifecycle_inbox:case_receive()}
        for _, pending in pairs(active) do cases[#cases + 1] = pending.response:case_receive() end
        local selected = channel.select(cases)
        if selected.channel == events then
            if not selected.ok or selected.value.kind == process.event.CANCEL then
                for _, pending in pairs(active) do pending.future:cancel() end
                ticker:stop()
                return
            end
        elseif selected.channel == lifecycle_inbox and selected.ok then
            local message = selected.value
            local envelope = bounds.object(message:payload():data())
            local request = envelope and lifecycle.request(envelope.request)
            local topic = envelope and bounds.line(envelope.topic, 128)
            if request and topic and topic:sub(1, #lifecycle.TOPIC + 1) == lifecycle.TOPIC .. "."
                and request.definition == definition and lifecycle.intent(request) then
                if request.phase == "ready" then
                    process.send(tostring(message:from()), topic, {version = 1, digest = request.digest, service = request.service,
                        phase = "ready", definition = definition, retention = "retain", ok = not waiting})
                elseif not waiting then
                    waiting = {recipient = tostring(message:from()), topic = topic, request = request}
                elseif waiting.request.digest == request.digest then
                    waiting.recipient, waiting.topic = tostring(message:from()), topic
                end
            end
        else
            if selected.channel == hints or selected.channel == ticker:channel() then settled_until_wake = {} end
            for session, pending in pairs(active) do
                if selected.channel == pending.response then
                    local reply, completion_error = pending.future:result()
                    local outcome = bounds.object(reply)
                    if completion_error or not outcome or outcome.ok ~= true then drain_error = "accepted session work remains uncertain" end
                    if completion_error then logger:error("Session turn worker ended without a report", {session = session, cause = tostring(completion_error)}) end
                    if outcome and outcome.ok == true and outcome.progressed ~= true then settled_until_wake[pending.work] = true end
                    active[session] = nil
                    break
                end
            end
            scan()
        end
        if waiting and next(active) == nil then
            local page, journal_error = threads_journal.invoke("work_scan", {limit = scheduler.MAX_SCAN, include_hooks = true})
            local problem = drain_error or journal_error or scheduler.drain_problem(page)
            local request = waiting.request
            process.send(waiting.recipient, waiting.topic, {version = 1, digest = request.digest, service = request.service,
                phase = "quiesce", definition = definition, retention = "retain", ok = problem == nil, message = problem})
            waiting = nil
        end
    end
end

return {main = main, pass = pass, turn_run = turn_run}

-- MIT. The scheduler owns drain evidence; delivery timeout leaves it uncertain.
local process = require("process")
local time = require("time")
local channel = require("channel")
local security = require("security")
local uuid = require("uuid")
local bounds = require("bounds")
local lifecycle = require("lifecycle")
local scheduler_work = require("scheduler")
local journal = require("threads_journal")
local function handle(raw: unknown): unknown
    if not security.can("bee.sessions.lifecycle", lifecycle.SERVICE) then error("host lifecycle authority required") end
    local request = lifecycle.request(raw)
    if not request or not lifecycle.intent(request) then error("invalid durable scheduler lifecycle intent") end
    local signals = assert(process.events())
    local scheduler = process.registry.lookup("bee.sessions.scheduler")
    if request.phase == "ready" then
        while not scheduler do
            local poll = time.after("25ms")
            local selected = channel.select({poll:case_receive(), signals:case_receive()})
            if not selected.ok then error("scheduler registration wait channel closed") end
            if selected.channel == signals and selected.value.kind == process.event.CANCEL then error("scheduler registration wait cancelled") end
            scheduler = process.registry.lookup("bee.sessions.scheduler")
        end
    end
    if not scheduler then
        if request.phase == "quiesce" then
            local actor = security.actor()
            if not actor or actor:meta().workspace_id ~= nil then error("global scheduler drain evidence is unavailable") end
            local page, journal_error = journal.invoke("work_scan", {limit = scheduler_work.MAX_SCAN, include_hooks = true})
            local problem = journal_error or scheduler_work.drain_problem(page)
            if problem then error(problem) end
            return {version = 1, digest = request.digest, service = request.service,
            phase = request.phase, definition = request.definition, retention = "retain", ok = true} end
        error("scheduler readiness is unavailable")
    end
    local topic = lifecycle.TOPIC .. "." .. tostring(assert(uuid.v4()))
    local inbox = assert(process.listen(topic, {message = true}))
    assert(process.monitor(scheduler))
    local sent, problem = process.send(scheduler, lifecycle.TOPIC, {request = request, topic = topic})
    if not sent then process.unlisten(inbox); error(tostring(problem)) end
    while true do
        local selected = channel.select({inbox:case_receive(), signals:case_receive()})
        if not selected.ok then process.unmonitor(scheduler); process.unlisten(inbox); error("scheduler lifecycle reply channel closed") end
        if selected.channel == signals then
            local event = selected.value
            if event.kind == process.event.CANCEL or (event.kind == process.event.EXIT and tostring(event.from) == tostring(scheduler)) then
                process.unmonitor(scheduler); process.unlisten(inbox)
                local result = bounds.object(event.result)
                error(event.kind == process.event.CANCEL and "scheduler lifecycle wait cancelled" or "scheduler exited before lifecycle acknowledgement: " .. tostring(result and result.error or "without a result"))
            end
            goto next_lifecycle_reply
        end
        local message = selected.value
        if message:from() == scheduler then
            local reply = bounds.object(message:payload():data())
            process.unmonitor(scheduler); process.unlisten(inbox)
            return reply
        end
        ::next_lifecycle_reply::
    end
end
return {handle = handle}

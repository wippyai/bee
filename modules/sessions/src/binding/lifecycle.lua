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
    local scheduler = process.registry.lookup("bee.sessions.scheduler")
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
    local sent, problem = process.send(scheduler, lifecycle.TOPIC, {request = request, topic = topic})
    if not sent then process.unlisten(inbox); error(tostring(problem)) end
    local deadline = time.after("60s")
    while true do
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then process.unlisten(inbox); error("scheduler drain or readiness is uncertain") end
        local message = selected.value
        if message:from() == scheduler then
            local reply = bounds.object(message:payload():data())
            process.unlisten(inbox)
            return reply
        end
    end
end
return {handle = handle}

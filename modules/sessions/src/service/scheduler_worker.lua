-- MIT. The scheduler process performs an immediate boot scan and a bounded
-- periodic pull; wake messages only shorten the delay.
local process = require("process")
local time = require("time")
local channel = require("channel")
local logger = require("logger")
local scheduler = require("scheduler")
local threads_journal = require("threads_journal")
local executors = require("executors")
local M = {}
M.WORKER = "bee.sessions.scheduler"
M.TOPIC_WAKE = "bee.sessions.scheduler.wake"
M.SCAN_INTERVAL = "5s"

local function pass(): string?
    local runtime, runtime_error = executors.runtime()
    if not runtime then return runtime_error or "executor registry is unavailable" end
    local service, service_error = scheduler.create(threads_journal.adapter(), runtime)
    if not service then return service_error or "scheduler could not be initialized" end
    local report, pass_error = service.run_pass()
    if not report then return pass_error or "scheduler scan failed" end
    for _, issue in ipairs(report.issues) do
        logger:error("Session scheduler work pass failed", {work = issue.work or "", stage = issue.stage, cause = issue.reason})
    end
    if report.uncertain > 0 then
        logger:error("Session executor reconciliation is uncertain", {count = report.uncertain})
    end
    return nil
end

local function pass_and_report()
    local err = pass()
    if err then logger:error("Session scheduler pass failed", {cause = err}) end
end

local function main()
    local events = assert(process.events())
    local hints = assert(process.listen(M.TOPIC_WAKE, {message = true}))
    local registered, register_error = process.registry.register(M.WORKER)
    if not registered then error("register session scheduler: " .. tostring(register_error)) end
    local ticker = time.ticker(M.SCAN_INTERVAL)
    pass_and_report()
    while true do
        local selected = channel.select({events:case_receive(), hints:case_receive(), ticker:channel():case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        else
            pass_and_report()
        end
    end
end

return {main = main, pass = pass}

-- MIT. The delivery worker: on every tick or wake it expires due requests,
-- forgets what retention allows, and drains the outbox through the thread
-- ingress under its own lease name. It never touches the authority
-- incarnation; a worker restart changes delivery ownership only.
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local service = require("service")
local outbox = require("outbox")
local M = {}
M.INTERVAL_MS = 5000
type Reconcile = () -> service.Reply
type Drain = () -> string?
function M.run_pass(reconcile: Reconcile, drain: Drain): string?
    local reply = reconcile()
    if not reply.ok then
        local fault = reply.error
        if fault then return fault.code .. ": " .. fault.message end
        return "reconcile returned a malformed refusal"
    end
    local drain_error = drain()
    if drain_error then return "drain approval outbox: " .. drain_error end
    return nil
end
function M.pass(): string?
    return M.run_pass(function(): service.Reply
        return service.reconcile({})
    end, function(): string?
        local db, open_error = service.open()
        if not db then return "open approval store: " .. tostring(open_error or "unavailable") end
        local _, drain_error = outbox.drain(db, tostring(process.pid()), outbox.thread_sender())
        db:release()
        return drain_error
    end)
end
local function pass_and_report()
    local pass_error = M.pass()
    if pass_error then logger:error("Approval worker pass failed", {cause = pass_error}) end
end
local function main()
    local events = assert(process.events())
    local inbox = assert(process.listen(service.TOPIC_WAKE, {message = true}))
    local registered, register_error = process.registry.register(service.WORKER_NAME)
    if not registered then error("register approval worker: " .. tostring(register_error)) end
    local ticker = time.ticker(tostring(M.INTERVAL_MS) .. "ms")
    pass_and_report()
    while true do
        local selected = channel.select({ticker:channel():case_receive(), inbox:case_receive(), events:case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        else
            pass_and_report()
        end
    end
end
return {main = main, pass = M.pass, run_pass = M.run_pass}

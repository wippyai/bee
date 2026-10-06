-- MIT. The delivery worker: on every tick or wake it expires due requests,
-- forgets what retention allows, and drains the outbox through the thread
-- ingress under its own lease name. It never touches the authority
-- incarnation; a worker restart changes delivery ownership only.
local process = require("process")
local logger = require("logger")
local worker = require("worker")
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
-- A failed pass is reported and runs again on the next tick or wake.
local function pass_and_report(): boolean
    local pass_error = M.pass()
    if pass_error then logger:error("Approval worker pass failed", {cause = pass_error}) end
    return true
end
local function main()
    worker.run({name = service.WORKER_NAME, wake = service.TOPIC_WAKE, every = tostring(M.INTERVAL_MS) .. "ms", pass = pass_and_report})
end
return {main = main, pass = M.pass, run_pass = M.run_pass}

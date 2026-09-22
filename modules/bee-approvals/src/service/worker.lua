-- MIT. The delivery worker: on every tick or wake it expires due requests,
-- forgets what retention allows, and drains the outbox through the thread
-- ingress under its own lease name. It never touches the authority
-- incarnation; a worker restart changes delivery ownership only.
local process = require("process")
local channel = require("channel")
local time = require("time")
local service = require("service")
local outbox = require("outbox")
local M = {}
M.INTERVAL_MS = 5000
function M.pass(): string?
    local reply = service.reconcile({})
    if not reply.ok then return reply.error and reply.error.message or "reconcile failed" end
    local db, open_error = service.open()
    if not db then return open_error end
    local _, drain_error = outbox.drain(db, tostring(process.pid()), outbox.thread_sender())
    db:release()
    return drain_error
end
local function main()
    local registered, register_error = process.registry.register(service.WORKER_NAME)
    if not registered then error("register approval worker: " .. tostring(register_error)) end
    local events = assert(process.events())
    local inbox = assert(process.listen(service.TOPIC_WAKE, {message = true}))
    local ticker = time.ticker(tostring(M.INTERVAL_MS) .. "ms")
    M.pass()
    while true do
        local selected = channel.select({ticker:channel():case_receive(), inbox:case_receive(), events:case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        else
            M.pass()
        end
    end
end
return {main = main, pass = M.pass}

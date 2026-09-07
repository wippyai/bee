-- MIT. One admitted start operation; work is a standalone process, not a view child.
local process = require("process")
local journal = require("journal")
local protocol = require("protocol")
local function start(value: unknown): {ok: boolean, error: string, created: boolean}
    if type(value) ~= "table" then return {ok = false, error = "Invalid run request", created = false} end
    local thread, run = protocol.id(value.thread), protocol.id(value.run)
    if not thread or not run then return {ok = false, error = "Invalid thread or run", created = false} end
    local log, open_error = journal.open(thread)
    if not log then return {ok = false, error = open_error or "Journal unavailable", created = false} end
    local claim, claim_error = log:claim(run)
    if not claim then return {ok = false, error = claim_error or "Run claim failed", created = false} end
    if not claim.created then return {ok = true, error = "", created = false} end
    local queued, queue_error = log:append(run, "queued", "test.run.queued", "{}")
    if not queued then return {ok = false, error = queue_error or "Could not record queued run", created = true} end
    local pid, spawn_error = process.spawn("bee.test_status:worker", "bee.test_status:workers", thread, run)
    if not pid then
        log:append(run, "launch-failed", "test.run.failed", '{"message":"Worker could not start"}')
        return {ok = false, error = tostring(spawn_error), created = true}
    end
    return {ok = true, error = "", created = true}
end
return {start = start}

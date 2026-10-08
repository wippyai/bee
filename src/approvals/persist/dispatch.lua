local sql = require("sql")
local process = require("process")
local resources = require("resources")
local bounds = require("bounds")
local M = {}
M.TOPIC = "bee.approvals.wake"
type Sender = (string, string, {[string]: unknown}) -> (boolean, string?)
function M.deliver(db: sql.DB, sender: Sender?): (integer?, string?)
    local consumers, err = resources.consumers()
    if not consumers then return nil, err end
    local sent = 0
    for _, consumer in ipairs(consumers) do
        local rows, query_error = db:query("SELECT event_id, approval_id, revision FROM bee_approval_events WHERE destination = ? AND acknowledged_at IS NULL ORDER BY seq LIMIT 64", {consumer.destination})
        if not rows or query_error then return nil, "read effect event outbox" end
        for _, row in ipairs(rows) do
            local event_id, approval_id = bounds.id(row.event_id), bounds.id(row.approval_id)
            local revision = bounds.integer(row.revision)
            if not event_id or not approval_id or not revision then return nil, "invalid effect event" end
            local body = {contract_version = 2, event_id = event_id, approval_id = approval_id, revision = revision, destination = consumer.destination}
            if sender then
                local ok, send_error = sender(consumer.worker_name, M.TOPIC, body)
                if not ok then return nil, send_error or "effect wake failed" end
                sent = sent + 1
            else
                local pid, lookup_error = process.registry.lookup(consumer.worker_name)
                if not lookup_error and pid then
                    local ok, send_error = process.send(tostring(pid), M.TOPIC, body)
                    if not ok then return nil, tostring(send_error or "effect wake failed") end
                    sent = sent + 1
                end
            end
        end
    end
    return sent, nil
end
return M

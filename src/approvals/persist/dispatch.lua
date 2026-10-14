local sql = require("sql")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local hash = require("hash")
local clock = require("clock")
local demand = require("demand")
local resources = require("resources")
local bounds = require("bounds")
local M = {}
M.TOPIC = "bee.approvals.wake"
type Sender = (string, string, {[string]: unknown}) -> (boolean, string?)
function M.notify_sessions(db: sql.DB): string?
    local rows, query_error = db:query([[SELECT e.event_id, e.destination, e.body_json, r.prompt_json, r.requester_id, r.workspace_id
        FROM bee_approval_events e JOIN bee_approval_requests r ON r.approval_id = e.approval_id
        WHERE e.acknowledged_at IS NULL AND e.destination LIKE 'requester:bs:%'
        AND e.kind IN ('approval.decided','approval.denied','approval.expired','approval.withdrawn','approval.superseded','approval.invalidated','effect.completed')
        ORDER BY e.seq LIMIT 64]])
    if not rows or query_error then return "read requesting-session events" end
    local failure: string? = nil
    for _, row in ipairs(rows) do
        local event = type(row.body_json) == "string" and bounds.object(json.decode(row.body_json)) or nil
        local destination, event_id = bounds.id(row.destination), bounds.id(row.event_id)
        local session, workspace = destination and bounds.id(destination:sub(#"requester:" + 1)), bounds.id(row.workspace_id)
        if not event or not event_id or not destination or not session or not workspace then return "invalid requesting-session event" end
        local actor = security.actor()
        if not actor then return "approval delivery identity is unavailable" end
        local identity, identity_error = security.new_actor(actor:id(), {workspace_id = workspace})
        if not identity then return tostring(identity_error) end
        local scoped, scope_error = funcs.new():with_actor(identity)
        if not scoped then return tostring(scope_error) end
        local prompt = type(row.prompt_json) == "string" and bounds.object(json.decode(row.prompt_json)) or nil
        local summary = prompt and type(prompt.text) == "string" and prompt.text or "Your request"
        local outcome = tostring(event.decision or event.state)
        local message = "Your request " .. tostring(event.approval_id) .. " was " .. outcome .. ": " .. summary
        local result = bounds.object(event.result)
        if result and type(result.error) == "string" then message = message .. "\nError: " .. result.error end
        if event.response ~= nil then message = message .. "\nAnswer: " .. tostring(json.encode(event.response)) end
        local key, key_error = hash.sha256(event_id)
        if not key then return tostring(key_error) end
        local raw, send_error = scoped:call("bee.threads.sessions.binding:send", {session = session, operation_key = "approval:" .. key, input = message})
        local reply = bounds.object(raw)
        if not send_error and reply and reply.ok == true then
            local _, ack_error = db:execute("UPDATE bee_approval_events SET acknowledged_at = COALESCE(acknowledged_at, ?) WHERE event_id = ? OR (destination = ? AND approval_id = ? AND kind = 'approval.requested')",
                {clock.stamp(clock.milliseconds()), event_id, destination, event.approval_id})
            if ack_error then return "acknowledge session notification" end
        else
            local fault = reply and bounds.object(reply.error)
            failure = failure or tostring(send_error or (fault and fault.message) or "session notification was refused")
        end
    end
    return failure
end
function M.deliver(db: sql.DB, sender: Sender?): (integer?, string?)
    local consumers, err = resources.consumers()
    if not consumers then return nil, err end
    local send: Sender = sender or function(name: string, topic: string, body: {[string]: unknown}): (boolean, string?)
        return demand.dispatch(name, {request_id = body.event_id, topic = topic, effect = body})
    end
    local sent = 0
    for _, consumer in ipairs(consumers) do
        local rows, query_error = db:query("SELECT event_id, approval_id, revision FROM bee_approval_events WHERE destination = ? AND acknowledged_at IS NULL ORDER BY seq LIMIT 64", {consumer.destination})
        if not rows or query_error then return nil, "read effect event outbox" end
        for _, row in ipairs(rows) do
            local event_id, approval_id = bounds.id(row.event_id), bounds.id(row.approval_id)
            local revision = bounds.integer(row.revision)
            if not event_id or not approval_id or not revision then return nil, "invalid effect event" end
            local body = {contract_version = 2, event_id = event_id, approval_id = approval_id, revision = revision, destination = consumer.destination}
            local ok, send_error = send(consumer.worker_name, M.TOPIC, body)
            if not ok then return nil, send_error or "effect wake failed" end
            sent = sent + 1
        end
    end
    return sent, nil
end
return M

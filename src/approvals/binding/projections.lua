-- MIT. Projections for the approvals authority.
local sql = require("sql")
local canonical = require("canonical")
local store = require("store")
local approval_outbox = require("outbox")
local lifecycle = require("lifecycle")
local part_model = require("part_model")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Object = part_model.Object
type Row = part_model.Row
local stamp = part_values.stamp
local text = part_values.text
local load = part_records.load
-- The thread projection names the outcome: a decision by its value, a
-- withdrawal as cancelled.
local function thread_state(state: string, decision: string?): string
    if state == "decided" then return decision or "denied" end
    if state == "withdrawn" then return "cancelled" end
    return state
end
-- One outbox row: the durable intent to project one body into the thread
-- under a stable event id. The row commits with the change it describes, so
-- a decision is never recorded without its projection being owed.
local function enqueue(tx: sql.Transaction, event_id: string, approval_id: string, revision: integer, thread_id: string, kind: string,
    body: Object, context_json: string?, now: integer, at: string): string?
    local encoded, encode_error = canonical.encode(body, 16384)
    if not encoded then return "encode projection: " .. tostring(encode_error) end
    return approval_outbox.enqueue(tx, {event_id = event_id, approval_id = approval_id, revision = revision,
        thread_id = thread_id, kind = kind, body_json = encoded, context_json = context_json, next_attempt_ms = now, created_at = at})
end
-- A transition record owes nobody anything: only a message commit creates
-- the recipient obligation the delivery layer carries. So the outcome is
-- also addressed to the requester, who is the thread member that asked.
local function notice_of(row: Row, revision: integer, outcome: string): Object
    local approval_id = text(row.approval_id) or ""
    return {message_id = approval_id .. ":" .. tostring(revision) .. ":notice", message_kind = "notification",
        recipient_ids = {text(row.requester_id) or ""}, content = {text = "Approval " .. approval_id .. " is " .. outcome .. "."}}
end
-- Every change is one revision: the history row, the inbox change and,
-- when the request projects onto a thread, the outbox rows all commit with it.
local function record_change(tx: sql.Transaction, row: Row, revision: integer, state: string, decision: string?, actor: string, reason: string, now: integer, body: Object?): string?
    local approval_id, workspace_id = text(row.approval_id) or "", text(row.workspace_id) or ""
    local at = stamp(now)
    local history_error = store.insert_history(tx, approval_id, revision, state, decision, actor, reason, at)
    if history_error then return "record approval history" end
    local inbox_error = store.insert_inbox(tx, workspace_id, approval_id, revision, at)
    if inbox_error then return "record inbox change" end
    local lifecycle_error = lifecycle.change(tx, part_records.view(row), revision, state, decision, actor, reason, at, body and body.response)
    if lifecycle_error then return lifecycle_error end
    local thread_id = text(row.thread_id)
    if thread_id and body then
        local kind = "approval.transition"
        if state == "pending" then kind = "approval.request" end
        local context_json: string? = nil
        local binding = row.binding
        if binding and binding.attempt_id then
            local encoded, encode_error = canonical.encode({action_id = binding.action_id, attempt_id = binding.attempt_id})
            if not encoded then return "encode thread projection context: " .. tostring(encode_error) end
            context_json = encoded
        end
        local event_id = approval_id .. ":" .. tostring(revision)
        local queued = enqueue(tx, event_id, approval_id, revision, thread_id, kind, body, context_json, now, at)
        if queued then return queued end
        -- Every terminal outcome is announced, a denial and an expiry as
        -- much as an approval: what leaves an agent waiting is not the
        -- refusal but the silence. The notice is a side effect of the
        -- decision and never a condition of it, so it rides the same outbox:
        -- a thread that refuses it retries and finally exhausts that row in
        -- view of `deliveries`, while the decision recorded here stands.
        if state ~= "pending" then
            local announced = enqueue(tx, event_id .. ":notice", approval_id, revision, thread_id, "message",
                notice_of(row, revision, thread_state(state, decision)), context_json, now, at)
            if announced then return announced end
        end
    end
    return nil
end
local function transition_body(row: Row, state: string, decision: string?, decider: string?, response: unknown, reason: string): Object
    return {approval_id = row.approval_id, expected_revision = row.revision, state = thread_state(state, decision), decider_id = decider, response = response, reason = reason}
end
-- Moves one pending request to a terminal state at the next revision.
local function settle(tx: sql.Transaction, row: Row, state: string, decision: string?, decider: string?, response: unknown, actor: string, reason: string, now: integer): (Row?, string?)
    local approval_id = text(row.approval_id) or ""
    local revision = row.revision + 1
    local body = transition_body(row, state, decision, decider, response, reason)
    local change_error = record_change(tx, row, revision, state, decision, actor, reason, now, body)
    if change_error then return nil, change_error end
    local response_json: string? = nil
    if response ~= nil then
        local encoded, encode_error = canonical.encode(response)
        if not encoded then return nil, "encode approval response: " .. tostring(encode_error) end
        response_json = encoded
    end
    local decided_at: string? = nil
    if state == "decided" then decided_at = stamp(now) end
    local update_error = store.transition(tx, approval_id, revision, state, decision, decider, decided_at, response_json, stamp(now))
    if update_error then return nil, "settle approval request" end
    if state == "decided" then
        local _, response_error = tx:execute("UPDATE bee_approval_decisions SET response_json = ? WHERE approval_id = ? AND revision = ?", {response_json, approval_id, revision})
        if response_error then return nil, "record decision response" end
    end
    return load(tx, approval_id)
end
-- Returns the current row and whether this call enforced the deadline.
local function expire_if_due(tx: sql.Transaction, row: Row, now: integer): (Row?, string?, boolean)
    if row.state ~= "pending" or row.expires_ms > now then return row, nil, false end
    local settled, err = settle(tx, row, "expired", nil, nil, nil, row.owner_node, "deadline passed at the owner", now)
    return settled, err, settled ~= nil
end
M.expire_if_due = expire_if_due
M.record_change = record_change
M.settle = settle
return M

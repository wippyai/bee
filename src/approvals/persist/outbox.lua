-- MIT. The durable outbox: every committed approval change owning a thread
-- projection is a row here; the worker leases due rows, delivers each
-- through the thread ingress under its stable event id, and acknowledges
-- only after the ingress reply. Delivery is at least once and the thread
-- deduplicates on the event id, so a lost acknowledgement repeats the
-- delivery rather than losing or duplicating the record.
local sql = require("sql")
local json = require("json")
local funcs = require("funcs")
local transaction = require("transaction")
local resources = require("resources")
local clock = require("clock")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.BATCH = 16
M.LEASE_MS = 30000
M.MAX_ATTEMPTS = 12
M.BACKOFF_BASE_MS = 1000
M.BACKOFF_MAX_MS = 300000
type Object = {[string]: unknown}
type Row = {event_id: string, approval_id: string, revision: integer, thread_id: string,
    kind: "approval.request" | "approval.transition" | "message", body_json: string, context_json: string?,
    attempts: integer, next_attempt_ms: integer, lease_owner: string?, lease_until_ms: integer?,
    acknowledged_at: string?, exhausted_at: string?, last_error: string?, created_at: string}
type Delivery = {event_id: string, approval_id: string, revision: integer, thread_id: string, kind: string, body: Object, context: Object?}
type Sender = (Delivery) -> (boolean, string?)
type Report = {delivered: integer, failed: integer, exhausted: integer, claimed: integer}
type Result = transaction.Result
type NewDelivery = {event_id: string, approval_id: string, revision: integer, thread_id: string,
    kind: string, body_json: string, context_json: string?, next_attempt_ms: integer, created_at: string}
local now_ms = clock.milliseconds
local stamp = clock.stamp
function M.enqueue(tx: sql.Transaction, value: NewDelivery): string?
    local _, err = tx:execute("INSERT INTO bee_approval_outbox (event_id, approval_id, revision, thread_id, kind, body_json, context_json, attempts, next_attempt_ms, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
        {value.event_id, value.approval_id, value.revision, value.thread_id, value.kind, value.body_json,
            value.context_json, value.next_attempt_ms, value.created_at})
    if err then return "record outbox delivery" end
    return nil
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function backoff(attempts: integer): integer
    local delay = M.BACKOFF_BASE_MS * (2 ^ math.min(attempts, 20))
    return math.floor(math.min(delay, M.BACKOFF_MAX_MS))
end
local function decode_row(raw: unknown): (Row?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "delivery row is not an object" end
    local event_id, approval_id, thread_id = bounds.id(value.event_id), bounds.id(value.approval_id), bounds.id(value.thread_id)
    local revision, attempts = bounds.count(value.revision), bounds.count(value.attempts)
    local next_attempt_ms = integer(value.next_attempt_ms)
    local kind: "approval.request" | "approval.transition" | "message" | nil = nil
    if value.kind == "approval.request" then kind = "approval.request"
    elseif value.kind == "approval.transition" then kind = "approval.transition"
    elseif value.kind == "message" then kind = "message" end
    local body_json = type(value.body_json) == "string" and value.body_json or nil
    local context_json: string? = nil
    if value.context_json ~= nil then
        if type(value.context_json) ~= "string" then return nil, "delivery row has invalid fields" end
        context_json = value.context_json
    end
    local lease_owner: string? = nil
    if value.lease_owner ~= nil then
        lease_owner = bounds.id(value.lease_owner)
        if not lease_owner then return nil, "delivery row has invalid fields" end
    end
    local last_error: string? = nil
    if value.last_error ~= nil then
        local raw_error = value.last_error
        if type(raw_error) ~= "string" then return nil, "delivery row has invalid fields" end
        last_error = raw_error
    end
    local lease_until_ms = value.lease_until_ms == nil and nil or integer(value.lease_until_ms)
    local acknowledged_at = value.acknowledged_at == nil and nil or bounds.timestamp(value.acknowledged_at)
    local exhausted_at = value.exhausted_at == nil and nil or bounds.timestamp(value.exhausted_at)
    if not event_id or not approval_id or not thread_id or not revision or revision < 1 or not attempts
        or not next_attempt_ms or next_attempt_ms < 0 or not kind or not body_json
        or (lease_owner ~= nil and not bounds.id(lease_owner)) or (value.lease_until_ms ~= nil and not lease_until_ms)
        or (value.acknowledged_at ~= nil and not acknowledged_at) or (value.exhausted_at ~= nil and not exhausted_at)
        or (last_error ~= nil and type(last_error) ~= "string") or type(value.created_at) ~= "string"
        or not bounds.timestamp(value.created_at) then
        return nil, "delivery row has invalid fields"
    end
    local row: Row = {event_id = event_id, approval_id = approval_id, revision = revision, thread_id = thread_id,
        kind = kind, body_json = body_json, context_json = context_json, attempts = attempts,
        next_attempt_ms = next_attempt_ms, lease_owner = lease_owner, lease_until_ms = lease_until_ms,
        acknowledged_at = acknowledged_at, exhausted_at = exhausted_at, last_error = last_error,
        created_at = value.created_at}
    return row, nil
end
-- Leases the due rows for this pass under the holder's name; a lease left
-- by a crashed holder lapses on its own and the row is delivered again.
local function claim(db: sql.DB, holder: string, now: integer): ({Row}?, string?)
    local rows: {Row} = {}
    local result = transaction.write(db, "approval", function(tx: sql.Transaction): Result
        local due, err = tx:query("SELECT * FROM bee_approval_outbox WHERE acknowledged_at IS NULL AND exhausted_at IS NULL AND next_attempt_ms <= ? AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at, event_id LIMIT ?",
            {now, now, M.BATCH})
        if err or not due then return transaction.failure("STORAGE", "read due deliveries") end
        for _, raw in ipairs(due) do
            local row, decode_error = decode_row(raw)
            if not row then return transaction.failure("STORAGE", "decode claimed delivery: " .. tostring(decode_error)) end
            local _, lease_error = tx:execute("UPDATE bee_approval_outbox SET lease_owner = ?, lease_until_ms = ? WHERE event_id = ?", {holder, now + M.LEASE_MS, row.event_id})
            if lease_error then return transaction.failure("STORAGE", "lease delivery") end
            rows[#rows + 1] = row
        end
        return transaction.success(nil, false)
    end)
    if not result.ok then return nil, result.message end
    return rows, nil
end
local function settle(db: sql.DB, row: Row, ok: boolean, err: string?, now: integer): string?
    local result = transaction.write(db, "approval", function(tx: sql.Transaction): Result
        if ok then
            local _, ack_error = tx:execute("UPDATE bee_approval_outbox SET acknowledged_at = ?, lease_owner = NULL, lease_until_ms = NULL, last_error = NULL WHERE event_id = ?", {stamp(now), row.event_id})
            if ack_error then return transaction.failure("STORAGE", "acknowledge delivery") end
            return transaction.success(nil, false)
        end
        local attempts = row.attempts + 1
        local exhausted_at: string? = nil
        if attempts >= M.MAX_ATTEMPTS then exhausted_at = stamp(now) end
        local _, fail_error = tx:execute("UPDATE bee_approval_outbox SET attempts = ?, next_attempt_ms = ?, lease_owner = NULL, lease_until_ms = NULL, last_error = ?, exhausted_at = ? WHERE event_id = ?",
            {attempts, now + backoff(attempts), err or "delivery failed", exhausted_at, row.event_id})
        if fail_error then return transaction.failure("STORAGE", "record delivery failure") end
        return transaction.success(nil, false)
    end)
    if not result.ok then return result.message end
    return nil
end
local function delivery_of(row: Row): (Delivery?, string?)
    local body_value, body_error = json.decode(row.body_json)
    local body = bounds.object(body_value)
    if not body then return nil, "delivery body is corrupt: " .. tostring(body_error or "expected an object") end
    local canonical_body, body_encode_error = canonical.encode(body, 16384)
    if canonical_body ~= row.body_json then return nil, "delivery body is corrupt: " .. tostring(body_encode_error or "canonical form differs") end
    local context: Object? = nil
    local context_json = row.context_json
    if context_json then
        local decoded, context_error = json.decode(context_json)
        context = bounds.object(decoded)
        if not context then return nil, "delivery context is corrupt: " .. tostring(context_error or "expected an object") end
        local canonical_context, context_encode_error = canonical.encode(context, 4096)
        if canonical_context ~= context_json then return nil, "delivery context is corrupt: " .. tostring(context_encode_error or "canonical form differs") end
    end
    return {event_id = row.event_id, approval_id = row.approval_id, revision = row.revision, thread_id = row.thread_id,
        kind = row.kind, body = body, context = context}, nil
end
-- drain: one pass over the due rows for one holder. The sender's reply is
-- the only thing that acknowledges a row.
function M.drain(db: sql.DB, holder: string, sender: Sender): (Report?, string?)
    local now = now_ms()
    local rows, claim_error = claim(db, holder, now)
    if not rows then return nil, claim_error end
    local report: Report = {delivered = 0, failed = 0, exhausted = 0, claimed = #rows}
    for _, row in ipairs(rows) do
        local delivery, decode_error = delivery_of(row)
        local ok, err = false, decode_error
        if delivery then ok, err = sender(delivery) end
        local settle_error = settle(db, row, ok, err, now_ms())
        if settle_error then return nil, settle_error end
        if ok then
            report.delivered = report.delivered + 1
        else
            report.failed = report.failed + 1
            if row.attempts + 1 >= M.MAX_ATTEMPTS then report.exhausted = report.exhausted + 1 end
        end
    end
    return report, nil
end
-- The sender that appends through the thread ingress as the caller's actor.
function M.thread_sender(executor: funcs.Executor?): Sender
    local client = executor or funcs.new()
    return function(delivery: Delivery): (boolean, string?)
        local reply, call_error = client:call(resources.THREAD_APPEND, {thread_id = delivery.thread_id, idempotency_key = delivery.event_id,
            owner_event_id = delivery.event_id, kind = delivery.kind, body = delivery.body, context = delivery.context})
        if call_error then return false, "thread ingress call failed: " .. tostring(call_error) end
        local envelope = bounds.object(reply)
        if not envelope or type(envelope.ok) ~= "boolean" then return false, "thread ingress returned a malformed reply" end
        if envelope.ok then return true, nil end
        local fault = bounds.object(envelope.error)
        if not fault then return false, "thread ingress returned a malformed refusal" end
        local code, message = bounds.id(fault.code), bounds.text(fault.message)
        if not code or not message then return false, "thread ingress returned a malformed refusal" end
        return false, code .. ": " .. message
    end
end
-- redeliver: a manager returns an exhausted row to the due queue.
function M.redeliver(db: sql.DB, event_id: string): (Row?, string?)
    local found: Row? = nil
    local result = transaction.write(db, "approval", function(tx: sql.Transaction): Result
        local rows, err = tx:query("SELECT * FROM bee_approval_outbox WHERE event_id = ?", {event_id})
        if err or not rows then return transaction.failure("STORAGE", "read delivery") end
        if #rows == 0 then return transaction.failure("NOT_FOUND", "delivery does not exist") end
        local row, decode_error = decode_row(rows[1])
        if not row then return transaction.failure("STORAGE", "decode delivery: " .. tostring(decode_error)) end
        if row.acknowledged_at ~= nil then return transaction.failure("INVALID_STATE", "delivery is acknowledged") end
        local _, reset_error = tx:execute("UPDATE bee_approval_outbox SET attempts = 0, next_attempt_ms = ?, lease_owner = NULL, lease_until_ms = NULL, exhausted_at = NULL WHERE event_id = ?", {now_ms(), event_id})
        if reset_error then return transaction.failure("STORAGE", "reset delivery") end
        local again, again_error = tx:query("SELECT * FROM bee_approval_outbox WHERE event_id = ?", {event_id})
        if again_error or not again then return transaction.failure("STORAGE", "read reset delivery") end
        if #again > 0 then
            local decoded, decode_again_error = decode_row(again[1])
            if not decoded then return transaction.failure("STORAGE", "decode reset delivery: " .. tostring(decode_again_error)) end
            found = decoded
        end
        return transaction.success(nil, false)
    end)
    if not result.ok then return nil, (result.code or "STORAGE") .. ": " .. tostring(result.message) end
    return found, nil
end
function M.view(row: Row): Object
    return {event_id = row.event_id, approval_id = row.approval_id, revision = row.revision, thread_id = row.thread_id, kind = row.kind, attempts = row.attempts, lease_owner = row.lease_owner,
        next_attempt_at = stamp(row.next_attempt_ms), acknowledged_at = row.acknowledged_at, exhausted_at = row.exhausted_at, last_error = row.last_error, created_at = row.created_at}
end
-- deliveries: the delivery state for one request, for its requester or a manager.
function M.deliveries(db: sql.DB, approval_id: string): ({Object}?, string?)
    local rows, err = db:query("SELECT * FROM bee_approval_outbox WHERE approval_id = ? ORDER BY revision, event_id", {approval_id})
    if err or not rows then return nil, "read deliveries" end
    local views: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw)
        if not row then return nil, "decode delivery status: " .. tostring(decode_error) end
        views[#views + 1] = M.view(row)
    end
    return views, nil
end
return M

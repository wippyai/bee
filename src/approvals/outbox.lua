-- MIT. The durable outbox: every committed approval change owning a thread
-- projection is a row here; the worker leases due rows, delivers each
-- through the thread ingress under its stable event id, and acknowledges
-- only after the ingress reply. Delivery is at least once and the thread
-- deduplicates on the event id, so a lost acknowledgement repeats the
-- delivery rather than losing or duplicating the record.
local sql = require("sql")
local json = require("json")
local funcs = require("funcs")
local time = require("time")
local transaction = require("transaction")
local resources = require("resources")
local M = {}
M.BATCH = 16
M.LEASE_MS = 30000
M.MAX_ATTEMPTS = 12
M.BACKOFF_BASE_MS = 1000
M.BACKOFF_MAX_MS = 300000
type Row = {[string]: unknown}
type Object = {[string]: unknown}
type Delivery = {event_id: string, approval_id: string, revision: integer, thread_id: string, kind: string, body: Object, context: Object?}
type Sender = (Delivery) -> (boolean, string?)
type Report = {delivered: integer, failed: integer, exhausted: integer, claimed: integer}
type Result = transaction.Result
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function stamp(ms: integer): string
    return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format("2006-01-02T15:04:05.000Z07:00")
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.floor(value)
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function backoff(attempts: integer): integer
    local delay = M.BACKOFF_BASE_MS * (2 ^ math.min(attempts, 20))
    return math.floor(math.min(delay, M.BACKOFF_MAX_MS))
end
-- Leases the due rows for this pass under the holder's name; a lease left
-- by a crashed holder lapses on its own and the row is delivered again.
local function claim(db: sql.DB, holder: string, now: integer): ({Row}?, string?)
    local rows: {Row} = {}
    local result = transaction.write(db, "approval", function(tx: sql.Transaction): Result
        local due, err = tx:query("SELECT * FROM bee_approval_outbox WHERE acknowledged_at IS NULL AND exhausted_at IS NULL AND next_attempt_ms <= ? AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at LIMIT ?",
            {now, now, M.BATCH})
        if err or not due then return transaction.failure("STORAGE", "read due deliveries") end
        for _, raw in ipairs(due) do
            local row = raw :: Row
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
        local attempts = (integer(row.attempts) or 0) + 1
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
    local body = json.decode(text(row.body_json) or "")
    if type(body) ~= "table" then return nil, "delivery body is corrupt" end
    local context: Object? = nil
    local context_json = text(row.context_json)
    if context_json then
        local decoded = json.decode(context_json)
        if type(decoded) ~= "table" then return nil, "delivery context is corrupt" end
        context = decoded :: Object
    end
    return {event_id = text(row.event_id) or "", approval_id = text(row.approval_id) or "", revision = integer(row.revision) or 0, thread_id = text(row.thread_id) or "",
        kind = text(row.kind) or "", body = body :: Object, context = context}, nil
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
            if (integer(row.attempts) or 0) + 1 >= M.MAX_ATTEMPTS then report.exhausted = report.exhausted + 1 end
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
        if call_error then return false, "thread ingress call failed" end
        if type(reply) ~= "table" then return false, "thread ingress returned no reply" end
        local typed = reply :: {ok: boolean, error: {code: string, message: string}?}
        if typed.ok then return true, nil end
        local fault = typed.error
        if fault then return false, fault.code .. ": " .. fault.message end
        return false, "thread ingress refused"
    end
end
-- redeliver: a manager returns an exhausted row to the due queue.
function M.redeliver(db: sql.DB, event_id: string): (Row?, string?)
    local found: Row? = nil
    local result = transaction.write(db, "approval", function(tx: sql.Transaction): Result
        local rows, err = tx:query("SELECT * FROM bee_approval_outbox WHERE event_id = ?", {event_id})
        if err or not rows then return transaction.failure("STORAGE", "read delivery") end
        if #rows == 0 then return transaction.failure("NOT_FOUND", "delivery does not exist") end
        local row = rows[1] :: Row
        if row.acknowledged_at ~= nil then return transaction.failure("INVALID_STATE", "delivery is acknowledged") end
        local _, reset_error = tx:execute("UPDATE bee_approval_outbox SET attempts = 0, next_attempt_ms = ?, lease_owner = NULL, lease_until_ms = NULL, exhausted_at = NULL WHERE event_id = ?", {now_ms(), event_id})
        if reset_error then return transaction.failure("STORAGE", "reset delivery") end
        local again = tx:query("SELECT * FROM bee_approval_outbox WHERE event_id = ?", {event_id})
        if again and #again > 0 then found = again[1] :: Row end
        return transaction.success(nil, false)
    end)
    if not result.ok then return nil, (result.code or "STORAGE") .. ": " .. tostring(result.message) end
    return found, nil
end
function M.view(row: Row): Object
    return {event_id = row.event_id, approval_id = row.approval_id, revision = row.revision, thread_id = row.thread_id, kind = row.kind, attempts = row.attempts, lease_owner = row.lease_owner,
        next_attempt_at = stamp(integer(row.next_attempt_ms) or 0), acknowledged_at = row.acknowledged_at, exhausted_at = row.exhausted_at, last_error = row.last_error, created_at = row.created_at}
end
-- deliveries: the delivery state for one request, for its requester or a manager.
function M.deliveries(db: sql.DB, approval_id: string): ({Object}?, string?)
    local rows, err = db:query("SELECT * FROM bee_approval_outbox WHERE approval_id = ? ORDER BY revision", {approval_id})
    if err or not rows then return nil, "read deliveries" end
    local views: {Object} = {}
    for _, row in ipairs(rows) do views[#views + 1] = M.view(row :: Row) end
    return views, nil
end
return M

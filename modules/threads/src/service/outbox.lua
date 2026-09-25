-- MIT. The durable forwarding outbox: cross-node sends persist here before
-- any byte crosses the wire. A pump leases due rows, delivers each through
-- the destination's admission, and settles only on the destination reply.
-- Delivery is at least once and the destination deduplicates on the
-- sender's stable idempotency key, so a lost reply repeats the delivery
-- rather than duplicating the message. A resent send replays its row
-- instead of enqueueing again. Rows belong to their sender: claim and
-- settle see only the caller's own rows, and a lease left by a crashed
-- pumper lapses on its own.
local sql = require("sql")
local uuid = require("uuid")
local time = require("time")
local json = require("json")
local bounds = require("bounds")
local transaction = require("transaction")
local M = {}
type Result = transaction.Result
type Row = {[string]: unknown}
type Object = {[string]: unknown}
M.BATCH = 16
M.LEASE_MS = 30000
M.MAX_ATTEMPTS = 12
M.BACKOFF_BASE_MS = 1000
M.BACKOFF_MAX_MS = 300000
local function failure(code: string, detail: string): Result return transaction.failure(code, detail) end
local function storage(detail: string): Result return transaction.storage_failure(detail) end
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
local function backoff(attempts: integer): integer
    local delay = M.BACKOFF_BASE_MS * (2 ^ math.min(attempts, 20))
    return math.floor(math.min(delay, M.BACKOFF_MAX_MS))
end
local function rows(tx: sql.Transaction, statement: string, params: {unknown}): ({Row}?, Result?)
    local found, err = tx:query(statement, params)
    if err or not found then return nil, storage("read forwarding outbox") end
    return found :: {Row}, nil
end
-- view: the bounded public state of a row. Content travels only with a
-- claimed delivery, never with a status, so a status check learns the
-- delivery state without re-reading the message.
function M.view(row: Row): Object
    local receipt: unknown = nil
    if type(row.receipt_json) == "string" and row.receipt_json ~= "" then
        local decoded = json.decode(row.receipt_json :: string)
        if decoded then receipt = decoded end
    end
    return {outbox_id = tostring(row.outbox_id), dest_node_id = tostring(row.dest_node_id),
        dest_action_id = tostring(row.dest_action_id), idempotency_key = tostring(row.idempotency_key),
        message_id = tostring(row.message_id), state = tostring(row.state),
        attempts = integer(row.attempts) or 0, last_error = row.last_error, receipt = receipt}
end
-- delivery: a claimed row shaped for the destination's admission. The
-- stored sender node travels beside the payload; admission stamps the
-- authenticated caller over it and the destination re-checks every grant.
function M.delivery(row: Row): Object
    local content: unknown = {}
    if type(row.content_json) == "string" and row.content_json ~= "" then
        content = json.decode(row.content_json :: string) or {}
    end
    local delivery: Object = {thread_id = tostring(row.dest_thread_id), target_action_id = tostring(row.dest_action_id),
        sender_thread_id = tostring(row.sender_thread_id), sender_action_id = tostring(row.sender_action_id),
        node_id = tostring(row.dest_node_id), workspace_id = tostring(row.dest_workspace_id),
        grant_epoch = integer(row.grant_epoch) or 0, idempotency_key = tostring(row.idempotency_key),
        message_id = tostring(row.message_id), content = content, payload_digest = tostring(row.payload_digest),
        caller_node_id = tostring(row.sender_node_id)}
    -- A reply carries the correlation its destination re-checks; an ordinary
    -- send leaves both fields empty.
    if type(row.in_reply_to_thread_id) == "string" and row.in_reply_to_thread_id ~= ""
        and type(row.in_reply_to_record_id) == "string" and row.in_reply_to_record_id ~= "" then
        delivery.in_reply_to = {thread_id = row.in_reply_to_thread_id, record_id = row.in_reply_to_record_id}
        if type(row.outcome) == "string" and row.outcome ~= "" then delivery.outcome = row.outcome end
    end
    return delivery
end
function M.find(tx: sql.Transaction, sender_thread_id: string, sender_actor: string, idempotency_key: string): (Row?, Result?)
    local found, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE sender_thread_id = ? AND sender_actor = ? AND idempotency_key = ?", {sender_thread_id, sender_actor, idempotency_key})
    if err then return nil, err end
    return found and found[1], nil
end
type Spec = {sender_thread_id: string, sender_actor: string, sender_action_id: string, sender_node_id: string, dest_node_id: string,
    dest_workspace_id: string, dest_thread_id: string, dest_action_id: string, grant_epoch: integer, idempotency_key: string,
    message_id: string, content_json: string, payload_digest: string, in_reply_to: {thread_id: string, record_id: string}?, outcome: string?}
function M.enqueue(tx: sql.Transaction, spec: Spec): (Row?, Result?)
    local outbox_id, id_error = uuid.v7()
    if id_error or not outbox_id then return nil, failure("INTERNAL", "allocate outbox identifier") end
    local now = now_ms()
    local reply_thread = spec.in_reply_to and spec.in_reply_to.thread_id or sql.NULL
    local reply_record = spec.in_reply_to and spec.in_reply_to.record_id or sql.NULL
    local _, write_error = tx:execute("INSERT INTO bee_thread_inbox_outbox (outbox_id, sender_thread_id, sender_actor, sender_action_id, sender_node_id, dest_node_id, dest_workspace_id, " ..
        "dest_thread_id, dest_action_id, grant_epoch, idempotency_key, message_id, content_json, payload_digest, in_reply_to_thread_id, in_reply_to_record_id, outcome, state, attempts, next_attempt_ms, created_at, updated_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?)",
        {outbox_id, spec.sender_thread_id, spec.sender_actor, spec.sender_action_id, spec.sender_node_id, spec.dest_node_id, spec.dest_workspace_id,
            spec.dest_thread_id, spec.dest_action_id, spec.grant_epoch, spec.idempotency_key, spec.message_id, spec.content_json,
            spec.payload_digest, reply_thread, reply_record, spec.outcome or sql.NULL, now, stamp(now), stamp(now)})
    if write_error then return nil, storage("enqueue forwarded send") end
    return M.find(tx, spec.sender_thread_id, spec.sender_actor, spec.idempotency_key)
end
function M.claim(tx: sql.Transaction, sender_actor: string, holder: string, limit: integer): ({Row}?, Result?)
    local now = now_ms()
    local due, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE sender_actor = ? AND state = 'queued' AND next_attempt_ms <= ? " ..
        "AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at LIMIT ?", {sender_actor, now, now, limit})
    if err then return nil, err end
    local claimed: {Row} = {}
    for _, row in ipairs(due or {}) do
        local _, lease_error = tx:execute("UPDATE bee_thread_inbox_outbox SET lease_owner = ?, lease_until_ms = ?, updated_at = ? WHERE outbox_id = ?",
            {holder, now + M.LEASE_MS, stamp(now), tostring(row.outbox_id)})
        if lease_error then return nil, storage("lease forwarded send") end
        row.lease_owner = holder
        claimed[#claimed + 1] = row
    end
    return claimed, nil
end
function M.settle(tx: sql.Transaction, sender_actor: string, outbox_id: string, delivered: boolean, receipt_json: string?, error_text: string?): Result?
    local now = now_ms()
    local found, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE outbox_id = ? AND sender_actor = ?", {outbox_id, sender_actor})
    if err then return err end
    local row = found and found[1]
    if not row then return failure("NOT_FOUND", "forwarded send is not queued") end
    if tostring(row.state) == "delivered" then return nil end
    if delivered then
        local _, ack_error = tx:execute("UPDATE bee_thread_inbox_outbox SET state = 'delivered', lease_owner = NULL, lease_until_ms = NULL, " ..
            "last_error = NULL, receipt_json = ?, updated_at = ? WHERE outbox_id = ?", {receipt_json or "", stamp(now), outbox_id})
        if ack_error then return storage("acknowledge forwarded send") end
        return nil
    end
    local attempts = (integer(row.attempts) or 0) + 1
    local final_state = attempts >= M.MAX_ATTEMPTS and "exhausted" or "queued"
    local _, fail_error = tx:execute("UPDATE bee_thread_inbox_outbox SET state = ?, attempts = ?, next_attempt_ms = ?, lease_owner = NULL, " ..
        "lease_until_ms = NULL, last_error = ?, updated_at = ? WHERE outbox_id = ?",
        {final_state, attempts, now + backoff(attempts), error_text or "delivery failed", stamp(now), outbox_id})
    if fail_error then return storage("record forwarded send failure") end
    return nil
end
-- touch: a failed delivery is retryable at once when its row is
-- redelivered through a resent send; the resend carries the attempt.
function M.retry(tx: sql.Transaction, row: Row): Result?
    local now = now_ms()
    local _, err = tx:execute("UPDATE bee_thread_inbox_outbox SET next_attempt_ms = ?, lease_owner = NULL, lease_until_ms = NULL, updated_at = ? WHERE outbox_id = ?",
        {now, stamp(now), tostring(row.outbox_id)})
    if err then return storage("retry forwarded send") end
    return nil
end
-- claim_pump_due: the node forwarding pump's lease call. The pump is the
-- node's own forwarding owner, not one sender's worker, so it leases due rows
-- across every sender under the same lease column; each claimed delivery
-- names the sender actor whose row it is so the pump can settle exactly that
-- row. A row already leased, or past its attempt ceiling, is never claimed.
function M.claim_pump_due(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    if bounds.fields(object, {"holder", "limit"}) then return failure("INVALID_ARGUMENT", "claim takes holder and limit only") end
    local holder = bounds.id(object.holder)
    if not holder then return failure("INVALID_ARGUMENT", "holder is not an identifier") end
    local limit = object.limit == nil and M.BATCH or bounds.integer(object.limit)
    if not limit or limit < 1 or limit > M.BATCH then return failure("INVALID_ARGUMENT", "limit is bounded by the outbox batch") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local now = now_ms()
        local due, read_error = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE state = 'queued' AND next_attempt_ms <= ? " ..
            "AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at LIMIT ?", {now, now, limit})
        if read_error then return read_error end
        local deliveries: {unknown} = {}
        for _, row in ipairs(due or {}) do
            local _, lease_error = tx:execute("UPDATE bee_thread_inbox_outbox SET lease_owner = ?, lease_until_ms = ?, updated_at = ? WHERE outbox_id = ?",
                {holder, now + M.LEASE_MS, stamp(now), tostring(row.outbox_id)})
            if lease_error then return storage("lease forwarded send") end
            local delivery = M.delivery(row)
            delivery.outbox_id = tostring(row.outbox_id)
            deliveries[#deliveries + 1] = delivery
        end
        return transaction.success({deliveries = deliveries}, false)
    end)
end
-- settle_pump: the pump's acknowledgment of one claimed row. It settles by
-- outbox identity, not by sender, because the pump leased the row itself;
-- the lease column proves the pump, not an arbitrary actor, held it.
function M.settle_pump(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    if bounds.fields(object, {"outbox_id", "delivered", "receipt", "error"}) then
        return failure("INVALID_ARGUMENT", "settle takes outbox_id, delivered, receipt and error only")
    end
    local outbox_id = bounds.id(object.outbox_id)
    if not outbox_id or type(object.delivered) ~= "boolean" then
        return failure("INVALID_ARGUMENT", "outbox_id and delivered are required")
    end
    local delivered: boolean = object.delivered == true
    local receipt_json: string? = nil
    if object.receipt ~= nil then
        local encoded = json.encode(object.receipt)
        if not encoded then return failure("INVALID_ARGUMENT", "receipt is not encodable") end
        receipt_json = encoded
    end
    local error_text: string? = nil
    if object.error ~= nil then
        error_text = bounds.text(object.error)
        if error_text == nil then return failure("INVALID_ARGUMENT", "error must be text") end
    end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local found, read_error = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE outbox_id = ?", {outbox_id})
        if read_error then return read_error end
        local row = found and found[1]
        if not row then return failure("NOT_FOUND", "forwarded send is not queued") end
        local failed = M.settle(tx, tostring(row.sender_actor), outbox_id, delivered, receipt_json, error_text)
        if failed then return failed end
        return transaction.success({outbox_id = outbox_id, delivered = delivered}, false)
    end)
end
-- claim_deliveries: the pump's lease call at the owner boundary. Claimed
-- rows shape directly into the destination's admission input.
function M.claim_deliveries(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    if bounds.fields(object, {"holder", "limit"}) then return failure("INVALID_ARGUMENT", "claim takes holder and limit only") end
    local holder = bounds.id(object.holder)
    if not holder then return failure("INVALID_ARGUMENT", "holder is not an identifier") end
    local limit = object.limit == nil and M.BATCH or bounds.integer(object.limit)
    if not limit or limit < 1 or limit > M.BATCH then return failure("INVALID_ARGUMENT", "limit is bounded by the outbox batch") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local claimed, err = M.claim(tx, actor, holder, limit)
        if err then return err end
        local deliveries: {unknown} = {}
        for _, row in ipairs(claimed or {}) do deliveries[#deliveries + 1] = M.delivery(row) end
        return transaction.success({deliveries = deliveries}, false)
    end)
end
-- settle_delivery: the pump's acknowledgment at the owner boundary, on the
-- destination reply. Only the row's sender settles it.
function M.settle_delivery(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    if bounds.fields(object, {"outbox_id", "delivered", "receipt", "error"}) then
        return failure("INVALID_ARGUMENT", "settle takes outbox_id, delivered, receipt and error only")
    end
    local outbox_id = bounds.id(object.outbox_id)
    if not outbox_id or type(object.delivered) ~= "boolean" then
        return failure("INVALID_ARGUMENT", "outbox_id and delivered are required")
    end
    local delivered: boolean = object.delivered == true
    local receipt_json: string? = nil
    if object.receipt ~= nil then
        local encoded = json.encode(object.receipt)
        if not encoded then return failure("INVALID_ARGUMENT", "receipt is not encodable") end
        receipt_json = encoded
    end
    local error_text: string? = nil
    if object.error ~= nil then
        error_text = bounds.text(object.error)
        if error_text == nil then return failure("INVALID_ARGUMENT", "error must be text") end
    end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local failed = M.settle(tx, actor, outbox_id, delivered, receipt_json, error_text)
        if failed then return failed end
        return transaction.success({outbox_id = outbox_id, delivered = delivered}, false)
    end)
end
return M

-- MIT. Durable forwarding rows and their transactional lifecycle.
local sql = require("sql")
local uuid = require("uuid")
local json = require("json")
local bounds = require("bounds")
local clock = require("clock")
local transaction = require("transaction")
local M = {}
M.LEASE_MS = 30000
M.MAX_ATTEMPTS = 12
M.BACKOFF_BASE_MS = 1000
M.BACKOFF_MAX_MS = 300000
type Object = {[string]: unknown}
type Result = transaction.Result
type State = "queued" | "delivered" | "exhausted"
type Row = {outbox_id: string, sender_thread_id: string, sender_actor: string, sender_action_id: string,
    sender_node_id: string, dest_node_id: string, dest_workspace_id: string, dest_thread_id: string,
    dest_action_id: string, grant_epoch: integer, idempotency_key: string, message_id: string,
    content_json: string, payload_digest: string, in_reply_to_thread_id: string?, in_reply_to_record_id: string?,
    outcome: string?, state: State, attempts: integer, next_attempt_ms: integer, lease_owner: string?,
    lease_until_ms: integer?, receipt_json: string?, last_error: string?, created_at: string, updated_at: string?}
type Spec = {sender_thread_id: string, sender_actor: string, sender_action_id: string, sender_node_id: string, dest_node_id: string,
    dest_workspace_id: string, dest_thread_id: string, dest_action_id: string, grant_epoch: integer, idempotency_key: string,
    message_id: string, content_json: string, payload_digest: string, in_reply_to: {thread_id: string, record_id: string}?, outcome: string?}
local function failure(code: string, detail: string): Result
    return transaction.failure(code, detail)
end
local function storage(detail: string): Result
    return transaction.storage_failure(detail)
end
local function corrupt(detail: string): Result
    return transaction.failure("STORAGE", detail)
end
local function rows(tx: sql.Transaction, statement: string, params: {unknown}): ({unknown}?, Result?)
    local found, err = tx:query(statement, params)
    if err or not found then return nil, storage("read forwarding outbox") end
    return found, nil
end
local function nullable(value: unknown): unknown?
    if value == nil or value == sql.NULL then return nil end
    return value
end
local function decode_row(raw: unknown): (Row?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "outbox row is not an object" end
    local outbox_id = bounds.id(value.outbox_id)
    local sender_thread_id, sender_actor = bounds.id(value.sender_thread_id), bounds.id(value.sender_actor)
    local sender_action_id, sender_node_id = bounds.id(value.sender_action_id), bounds.id(value.sender_node_id)
    local dest_node_id, dest_workspace_id = bounds.id(value.dest_node_id), bounds.id(value.dest_workspace_id)
    local dest_thread_id, dest_action_id = bounds.id(value.dest_thread_id), bounds.id(value.dest_action_id)
    local grant_epoch, attempts = bounds.integer(value.grant_epoch), bounds.count(value.attempts)
    local idempotency_key, message_id = bounds.id(value.idempotency_key), bounds.id(value.message_id)
    if type(value.content_json) ~= "string" then return nil, "outbox content is not JSON text" end
    local content_json = value.content_json
    local payload_digest = value.payload_digest
    local state: State? = nil
    if value.state == "queued" then state = "queued"
    elseif value.state == "delivered" then state = "delivered"
    elseif value.state == "exhausted" then state = "exhausted" end
    local next_attempt_ms = bounds.integer(value.next_attempt_ms)
    local raw_reply_thread = nullable(value.in_reply_to_thread_id)
    local raw_reply_record = nullable(value.in_reply_to_record_id)
    local raw_outcome = nullable(value.outcome)
    local raw_lease_owner = nullable(value.lease_owner)
    local raw_lease_until = nullable(value.lease_until_ms)
    local raw_receipt = nullable(value.receipt_json)
    local raw_error = nullable(value.last_error)
    local raw_updated_at = nullable(value.updated_at)
    local in_reply_to_thread_id = raw_reply_thread == nil and nil or bounds.id(raw_reply_thread)
    local in_reply_to_record_id = raw_reply_record == nil and nil or bounds.id(raw_reply_record)
    local outcome = raw_outcome == nil and nil or bounds.id(raw_outcome)
    local lease_owner = raw_lease_owner == nil and nil or bounds.id(raw_lease_owner)
    local lease_until_ms = raw_lease_until == nil and nil or bounds.integer(raw_lease_until)
    local receipt_json: string? = nil
    if raw_receipt ~= nil then
        if type(raw_receipt) ~= "string" then return nil, "outbox row receipt_json is not text" end
        receipt_json = raw_receipt
    end
    local last_error: string? = nil
    if raw_error ~= nil then
        if type(raw_error) ~= "string" then return nil, "outbox row last_error is not text" end
        last_error = raw_error
    end
    local updated_at = raw_updated_at == nil and nil or bounds.timestamp(raw_updated_at)
    if not outbox_id then return nil, "outbox row has invalid id" end
    if not sender_thread_id then return nil, "outbox row has invalid sender thread" end
    if not sender_actor then return nil, "outbox row has invalid sender actor" end
    if not sender_action_id then return nil, "outbox row has invalid sender action" end
    if not sender_node_id then return nil, "outbox row has invalid sender node" end
    if not dest_node_id then return nil, "outbox row has invalid destination node" end
    if not dest_workspace_id then return nil, "outbox row has invalid destination workspace" end
    if not dest_thread_id then return nil, "outbox row has invalid destination thread" end
    if not dest_action_id then return nil, "outbox row has invalid destination action" end
    if grant_epoch == nil or grant_epoch < 1 then return nil, "outbox row has invalid grant epoch" end
    if not idempotency_key then return nil, "outbox row has invalid idempotency key" end
    if not message_id then return nil, "outbox row has invalid message id" end
    if type(payload_digest) ~= "string" then return nil, "outbox row has invalid payload digest" end
    if not state then return nil, "outbox row has invalid state" end
    if next_attempt_ms == nil or next_attempt_ms < 0 then return nil, "outbox row has invalid retry deadline" end
    if attempts == nil then return nil, "outbox row has invalid attempts" end
    if #payload_digest ~= 64 or not payload_digest:match("^[0-9a-f]+$") then return nil, "outbox row has invalid payload digest" end
    if ((raw_reply_thread ~= nil) ~= (in_reply_to_thread_id ~= nil))
        or ((raw_reply_record ~= nil) ~= (in_reply_to_record_id ~= nil))
        or ((in_reply_to_thread_id ~= nil) ~= (in_reply_to_record_id ~= nil)) then
        return nil, "outbox row has invalid reply address"
    end
    if (raw_outcome ~= nil and not outcome) or (outcome ~= nil and in_reply_to_thread_id == nil) then
        return nil, "outbox row has invalid reply outcome"
    end
    if (raw_lease_owner ~= nil and not lease_owner) or (raw_lease_until ~= nil and not lease_until_ms) then
        return nil, "outbox row has invalid lease"
    end
    if raw_updated_at ~= nil and not updated_at then return nil, "outbox row has invalid update time" end
    if type(value.created_at) ~= "string" or not bounds.timestamp(value.created_at) then return nil, "outbox row has invalid creation time" end
    local row: Row = {outbox_id = outbox_id, sender_thread_id = sender_thread_id, sender_actor = sender_actor,
        sender_action_id = sender_action_id, sender_node_id = sender_node_id, dest_node_id = dest_node_id,
        dest_workspace_id = dest_workspace_id, dest_thread_id = dest_thread_id, dest_action_id = dest_action_id,
        grant_epoch = grant_epoch, idempotency_key = idempotency_key, message_id = message_id, content_json = content_json,
        payload_digest = payload_digest, in_reply_to_thread_id = in_reply_to_thread_id,
        in_reply_to_record_id = in_reply_to_record_id, outcome = outcome, state = state, attempts = attempts,
        next_attempt_ms = next_attempt_ms, lease_owner = lease_owner, lease_until_ms = lease_until_ms,
        receipt_json = receipt_json, last_error = last_error, created_at = value.created_at, updated_at = updated_at}
    return row, nil
end
local function delivery(row: Row, include_outbox_id: boolean?): (Object?, string?)
    local content_value, content_error = json.decode(row.content_json)
    local content = bounds.object(content_value)
    if not content then return nil, "forwarded delivery content is corrupt: " .. tostring(content_error or "expected an object") end
    local value: Object = {thread_id = row.dest_thread_id,
        target_action_id = row.dest_action_id, sender_thread_id = row.sender_thread_id,
        sender_action_id = row.sender_action_id, node_id = row.dest_node_id, workspace_id = row.dest_workspace_id,
        grant_epoch = row.grant_epoch, idempotency_key = row.idempotency_key, message_id = row.message_id,
        content = content, payload_digest = row.payload_digest, caller_node_id = row.sender_node_id}
    if include_outbox_id then value.outbox_id = row.outbox_id end
    if row.in_reply_to_thread_id and row.in_reply_to_record_id then
        value.in_reply_to = {thread_id = row.in_reply_to_thread_id, record_id = row.in_reply_to_record_id}
        if row.outcome then value.outcome = row.outcome end
    end
    return value, nil
end
function M.find(tx: sql.Transaction, sender_thread_id: string, sender_actor: string, idempotency_key: string): (Row?, Result?)
    local found, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE sender_thread_id = ? AND sender_actor = ? AND idempotency_key = ?",
        {sender_thread_id, sender_actor, idempotency_key})
    if err then return nil, err end
    if not found or #found == 0 then return nil, nil end
    local row, decode_error = decode_row(found[1])
    if not row then return nil, corrupt("decode forwarding outbox row: " .. tostring(decode_error)) end
    return row, nil
end
function M.enqueue(tx: sql.Transaction, spec: Spec): (Row?, Result?)
    local outbox_id, id_error = uuid.v7()
    if id_error or not outbox_id then return nil, failure("INTERNAL", "allocate outbox identifier") end
    local now = clock.milliseconds()
    local reply_thread = spec.in_reply_to and spec.in_reply_to.thread_id or sql.NULL
    local reply_record = spec.in_reply_to and spec.in_reply_to.record_id or sql.NULL
    local _, write_error = tx:execute("INSERT INTO bee_thread_inbox_outbox (outbox_id, sender_thread_id, sender_actor, sender_action_id, sender_node_id, dest_node_id, dest_workspace_id, " ..
        "dest_thread_id, dest_action_id, grant_epoch, idempotency_key, message_id, content_json, payload_digest, in_reply_to_thread_id, in_reply_to_record_id, outcome, state, attempts, next_attempt_ms, created_at, updated_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?)",
        {outbox_id, spec.sender_thread_id, spec.sender_actor, spec.sender_action_id, spec.sender_node_id, spec.dest_node_id, spec.dest_workspace_id,
            spec.dest_thread_id, spec.dest_action_id, spec.grant_epoch, spec.idempotency_key, spec.message_id, spec.content_json,
            spec.payload_digest, reply_thread, reply_record, spec.outcome or sql.NULL, now, clock.stamp(now), clock.stamp(now)})
    if write_error then return nil, storage("enqueue forwarded send") end
    return M.find(tx, spec.sender_thread_id, spec.sender_actor, spec.idempotency_key)
end
local function backoff(attempts: integer): integer
    local delay = M.BACKOFF_BASE_MS * (2 ^ math.min(attempts, 20))
    return math.floor(math.min(delay, M.BACKOFF_MAX_MS))
end
local function claim_due(tx: sql.Transaction, statement: string, params: {unknown}, holder: string, now: integer): ({Row}?, Result?)
    local due, err = rows(tx, statement, params)
    if err then return nil, err end
    local claimed: {Row} = {}
    for _, raw in ipairs(due or {}) do
        local row, decode_error = decode_row(raw)
        if not row then return nil, corrupt("decode claimed forwarding row: " .. tostring(decode_error)) end
        local _, delivery_error = delivery(row)
        if delivery_error then return nil, corrupt("decode claimed forwarding delivery: " .. delivery_error) end
        local _, lease_error = tx:execute("UPDATE bee_thread_inbox_outbox SET lease_owner = ?, lease_until_ms = ?, updated_at = ? WHERE outbox_id = ?",
            {holder, now + M.LEASE_MS, clock.stamp(now), row.outbox_id})
        if lease_error then return nil, storage("lease forwarded send") end
        row.lease_owner, row.lease_until_ms, row.updated_at = holder, now + M.LEASE_MS, clock.stamp(now)
        claimed[#claimed + 1] = row
    end
    return claimed, nil
end
function M.claim(tx: sql.Transaction, sender_actor: string, holder: string, limit: integer): ({Row}?, Result?)
    local now = clock.milliseconds()
    return claim_due(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE sender_actor = ? AND state = 'queued' AND next_attempt_ms <= ? " ..
        "AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at LIMIT ?", {sender_actor, now, now, limit}, holder, now)
end
function M.claim_pump_due(tx: sql.Transaction, holder: string, limit: integer): ({Object}?, Result?)
    local now = clock.milliseconds()
    local claimed, err = claim_due(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE state = 'queued' AND next_attempt_ms <= ? " ..
        "AND (lease_until_ms IS NULL OR lease_until_ms <= ?) ORDER BY created_at LIMIT ?", {now, now, limit}, holder, now)
    if err or not claimed then return nil, err end
    local deliveries: {Object} = {}
    for _, row in ipairs(claimed) do
        local item, delivery_error = delivery(row, true)
        if not item then return nil, storage("decode claimed forwarding delivery: " .. tostring(delivery_error)) end
        deliveries[#deliveries + 1] = item
    end
    return deliveries, nil
end
local function settle_row(tx: sql.Transaction, row: Row, delivered: boolean, receipt_json: string?, error_text: string?): Result?
    local now = clock.milliseconds()
    if row.state == "delivered" then return nil end
    if delivered then
        local _, ack_error = tx:execute("UPDATE bee_thread_inbox_outbox SET state = 'delivered', lease_owner = NULL, lease_until_ms = NULL, " ..
            "last_error = NULL, receipt_json = ?, updated_at = ? WHERE outbox_id = ?", {receipt_json or "", clock.stamp(now), row.outbox_id})
        if ack_error then return storage("acknowledge forwarded send") end
        return nil
    end
    local attempts = row.attempts + 1
    local final_state = attempts >= M.MAX_ATTEMPTS and "exhausted" or "queued"
    local _, fail_error = tx:execute("UPDATE bee_thread_inbox_outbox SET state = ?, attempts = ?, next_attempt_ms = ?, lease_owner = NULL, " ..
        "lease_until_ms = NULL, last_error = ?, updated_at = ? WHERE outbox_id = ?",
        {final_state, attempts, now + backoff(attempts), error_text or "delivery failed", clock.stamp(now), row.outbox_id})
    if fail_error then return storage("record forwarded send failure") end
    return nil
end
function M.settle(tx: sql.Transaction, sender_actor: string, outbox_id: string, delivered: boolean, receipt_json: string?, error_text: string?): Result?
    local found, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE outbox_id = ? AND sender_actor = ?", {outbox_id, sender_actor})
    if err then return err end
    if not found or #found == 0 then return failure("NOT_FOUND", "forwarded send is not queued") end
    local row, decode_error = decode_row(found[1])
    if not row then return corrupt("decode forwarded send: " .. tostring(decode_error)) end
    return settle_row(tx, row, delivered, receipt_json, error_text)
end
function M.settle_pump(tx: sql.Transaction, outbox_id: string, delivered: boolean, receipt_json: string?, error_text: string?): Result?
    local found, err = rows(tx, "SELECT * FROM bee_thread_inbox_outbox WHERE outbox_id = ?", {outbox_id})
    if err then return err end
    if not found or #found == 0 then return failure("NOT_FOUND", "forwarded send is not queued") end
    local row, decode_error = decode_row(found[1])
    if not row then return corrupt("decode forwarded send: " .. tostring(decode_error)) end
    return settle_row(tx, row, delivered, receipt_json, error_text)
end
function M.retry(tx: sql.Transaction, row: Row): Result?
    local now = clock.milliseconds()
    local _, err = tx:execute("UPDATE bee_thread_inbox_outbox SET next_attempt_ms = ?, lease_owner = NULL, lease_until_ms = NULL, updated_at = ? WHERE outbox_id = ?",
        {now, clock.stamp(now), row.outbox_id})
    if err then return storage("retry forwarded send") end
    return nil
end
function M.delivery(row: Row): (Object?, string?)
    return delivery(row)
end
function M.view(row: Row): (Object?, string?)
    local receipt: unknown = nil
    if row.receipt_json and row.receipt_json ~= "" then
        receipt = json.decode(row.receipt_json)
        if receipt == nil then return nil, "forwarded send receipt is corrupt" end
    end
    local view: Object = {outbox_id = row.outbox_id, dest_node_id = row.dest_node_id, dest_action_id = row.dest_action_id,
        idempotency_key = row.idempotency_key, message_id = row.message_id, state = row.state,
        attempts = row.attempts, last_error = row.last_error}
    if receipt ~= nil then view.receipt = receipt end
    return view, nil
end
function M.next_deadline(db: sql.DB): (integer?, string?)
    local rows, problem = db:query("SELECT MIN(MAX(next_attempt_ms, COALESCE(lease_until_ms, next_attempt_ms))) AS due FROM bee_thread_inbox_outbox WHERE state = 'queued'")
    if not rows then return nil, tostring(problem) end
    local due = rows[1] and tonumber(rows[1].due) or nil
    return due and math.floor(due) or nil, nil
end
return M

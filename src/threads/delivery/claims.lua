-- MIT. Claims over recipient obligations: a batch claims pending messages
-- for the calling recipient, dispatch intent is recorded before bytes leave,
-- acknowledgment or release settles the claim, expiry makes it uncertain,
-- and reconciliation decides the rest. Every transition is a delivery.mark
-- record committed with the index change.
local sql = require("sql")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local record_types = require("record_types")
local access = require("access")
local reader = require("reader")
local transaction = require("transaction")
local owner = require("owner")
local authority = require("authority")
local function values_optional(object: {[string]: unknown}, name: string): (string?, boolean)
    local id, valid = values.optional_id(object, name)
    return id, valid
end
local M = {}
type Result = transaction.Result
type Claimed = {delivery_id: string, message_id: string, record_id: string, sequence: integer, mark_record_id: string}
M.CLAIM_TTL_SECONDS = 300
M.CHANNELS = {"wait", "push", "mcp", "native"}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
local function seconds_later(now: string, seconds: integer): string
    local year, month, day, hour, minute, second = now:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    local base = os.time({year = tonumber(year) or 1970, month = tonumber(month) or 1, day = tonumber(day) or 1,
        hour = tonumber(hour) or 0, min = tonumber(minute) or 0, sec = tonumber(second) or 0})
    return os.date("!%Y-%m-%dT%H:%M:%S", base + seconds) .. ".000Z"
end
M.seconds_later = seconds_later
-- Loads the thread, the caller's membership and the owner incarnation that
-- every claim transition needs.
local function open_thread(tx: sql.Transaction, actor: string, operation: string, mutation: authority.Mutation): (reader.Head?, reader.Member?, integer?, Result?)
    local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
    if not head or not caller then return nil, nil, nil, denied or failure("DENIED", "caller is not a member of the thread") end
    local replayed, replay_err = authority.replay(tx, actor, operation, mutation)
    if replay_err then return nil, nil, nil, storage(replay_err) end
    if replayed then return nil, nil, nil, replayed end
    if head.state ~= "open" then return nil, nil, nil, failure("INVALID_STATE", "thread is closed") end
    local incarnation, incarnation_err = owner.current(tx)
    if incarnation_err then return nil, nil, nil, storage(incarnation_err) end
    if not incarnation then return nil, nil, nil, failure("UNAVAILABLE", "the thread owner has not started") end
    return head, caller, incarnation, nil
end
local function mark(tx: sql.Transaction, head: reader.Head, actor: string, delivery: reader.Delivery, state: record_types.DeliveryState,
    evidence_ref: string?, owed: integer): (string?, Result?)
    local body: record_types.DeliveryMark = {delivery_id = delivery.delivery_id, message_id = delivery.message_id, recipient_id = delivery.recipient_id,
        state = state, owner_epoch = delivery.owner_incarnation, channel = delivery.channel, evidence_ref = evidence_ref}
    local committed, refused = authority.commit_record(tx, head, "delivery.mark", actor, "bee", body, {}, nil, nil, owed)
    if not committed then return nil, refused or failure("INTERNAL", "commit failed") end
    return committed.record_id, nil
end
local function load_delivery(tx: sql.Transaction, thread_id: string, value: unknown): (reader.Delivery?, Result?)
    local delivery_id = bounds.id(value)
    if not delivery_id then return nil, failure("INVALID_ARGUMENT", "delivery_id is not an identifier") end
    local delivery, err = reader.delivery(tx, thread_id, delivery_id)
    if err then return nil, storage(err) end
    if not delivery then return nil, failure("NOT_FOUND", "delivery does not exist") end
    return delivery, nil
end
local function require_claimant(delivery: reader.Delivery, actor: string, incarnation: integer): Result?
    if delivery.claimant_actor ~= actor then return failure("DENIED", "only the claimant settles its delivery") end
    if delivery.owner_incarnation ~= incarnation then return failure("CONFLICT", "the claim belongs to an earlier owner incarnation; reconcile it") end
    return nil
end
type Batch = {batch_id: string?, deliveries: {Claimed}, owner_incarnation: integer, expires_at: string?}
-- Claims every pending obligation of the actor, up to limit, as one batch.
-- An empty result creates nothing.
function M.claim_pending(tx: sql.Transaction, head: reader.Head, actor: string, incarnation: integer, consumer_id: string, channel: string, limit: integer,
    key: string, digest: string, turn_id: string?, attempt_id: string?): (Batch?, Result?)
    local pending, pending_err = reader.pending_obligations(tx, head.thread_id, actor, limit)
    if not pending then return nil, storage(pending_err or "read pending obligations") end
    if #pending == 0 then
        local none: {Claimed} = {}
        local empty: Batch = {deliveries = none, owner_incarnation = incarnation}
        return empty, nil
    end
    local batch_id, batch_err = transaction.record_id()
    if not batch_id then return nil, failure("INTERNAL", batch_err or "allocate batch identifier") end
    local now = transaction.now()
    local expires_at = seconds_later(now, M.CLAIM_TTL_SECONDS)
    local insert_err = transaction.insert_batch(tx, batch_id, head.thread_id, actor, consumer_id, key, digest, turn_id, attempt_id, now)
    if insert_err then return nil, storage(insert_err) end
    local claimed: {Claimed} = {}
    for index, obligation in ipairs(pending) do
        local delivery_id, id_err = transaction.record_id()
        if not delivery_id then return nil, failure("INTERNAL", id_err or "allocate delivery identifier") end
        local delivery: reader.Delivery = {delivery_id = delivery_id, message_id = obligation.message_id, recipient_id = actor, batch_id = batch_id,
            consumer_id = consumer_id, claimant_actor = actor, channel = channel, owner_incarnation = incarnation, state = "claimed", expires_at = expires_at}
        -- The claimed mark is committed now; the terminal mark is owed.
        local mark_id, refused = mark(tx, head, actor, delivery, "claimed", nil, 1)
        if not mark_id then return nil, refused or failure("INTERNAL", "commit failed") end
        local delivery_err = transaction.insert_delivery(tx, head.thread_id, delivery_id, obligation.message_id, actor, batch_id, consumer_id, channel, incarnation, now, expires_at, mark_id)
        if delivery_err then return nil, storage(delivery_err) end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, obligation.message_id, actor, "claimed", delivery_id)
        if obligation_err then return nil, storage(obligation_err) end
        claimed[index] = {delivery_id = delivery_id, message_id = obligation.message_id, record_id = obligation.message_record_id,
            sequence = obligation.created_sequence, mark_record_id = mark_id}
    end
    return {batch_id = batch_id, deliveries = claimed, owner_incarnation = incarnation, expires_at = expires_at}, nil
end
-- Loads the thread and the caller for a claim: an open thread, a submitting
-- member, an owner that has started, and no stored reply for this key.
function M.open_for_claim(tx: sql.Transaction, actor: string, operation: string, mutation: authority.Mutation): (reader.Head?, integer?, Result?)
    local head, caller, incarnation, stop = open_thread(tx, actor, operation, mutation)
    if not head or not caller or not incarnation then return nil, nil, stop or failure("INTERNAL", "thread unavailable") end
    if not access.submits(caller.role) then return nil, nil, failure("DENIED", "observers hold no obligations") end
    return head, incarnation, nil
end
function M.claim(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "consumer_id", "limit", "channel", "turn_id", "attempt_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local consumer_id = bounds.id(object.consumer_id)
    if not consumer_id then return failure("INVALID_ARGUMENT", "consumer_id is not an identifier") end
    local limit = bounds.MAX_PAGE_RECORDS
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > bounds.MAX_PAGE_RECORDS then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS)) end
        limit = number
    end
    local channel = "wait"
    if object.channel ~= nil then
        local declared = bounds.member(object.channel, M.CHANNELS)
        if not declared then return failure("INVALID_ARGUMENT", "channel must be wait, push, mcp or native") end
        channel = declared
    end
    local turn_id: string? = nil
    local attempt_id: string? = nil
    if object.turn_id ~= nil or object.attempt_id ~= nil then
        turn_id, attempt_id = bounds.id(object.turn_id), bounds.id(object.attempt_id)
        if not turn_id or not attempt_id then return failure("INVALID_ARGUMENT", "turn_id and attempt_id come together") end
    end
    local digest, digest_error = canonical.encode({consumer_id = consumer_id, limit = limit, channel = channel, turn_id = turn_id, attempt_id = attempt_id})
    if not digest then return failure("INVALID_ARGUMENT", digest_error or "request is not encodable") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, incarnation, stop = M.open_for_claim(tx, actor, "claim", mutation)
        if not head or not incarnation then return stop or failure("INTERNAL", "thread unavailable") end
        if turn_id and attempt_id then
            local turn, turn_err = reader.turn(tx, head.thread_id, turn_id)
            if turn_err then return storage(turn_err) end
            if not turn or turn.attempt_id ~= attempt_id then return failure("INVALID_ARGUMENT", "turn does not belong to the attempt") end
            if turn.ended then return failure("INVALID_STATE", "turn has ended") end
        end
        local batch, refused = M.claim_pending(tx, head, actor, incarnation, consumer_id, channel, limit, mutation.idempotency_key, digest, turn_id, attempt_id)
        if not batch then return refused or failure("INTERNAL", "claim failed") end
        if #batch.deliveries == 0 then return transaction.success(batch, false) end
        return authority.remember(tx, actor, "claim", mutation, batch)
    end)
end
local function settle(operation: string, fields: {string}, db: sql.DB, actor: string, request: unknown,
    apply: (sql.Transaction, reader.Head, integer, reader.Delivery, {[string]: unknown}) -> Result): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local allowed: {string} = {"thread_id", "idempotency_key", "delivery_id"}
    for _, name in ipairs(fields) do allowed[#allowed + 1] = name end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, incarnation, stop = open_thread(tx, actor, operation, mutation)
        if not head or not caller or not incarnation then return stop or failure("INTERNAL", "thread unavailable") end
        local delivery, missing = load_delivery(tx, head.thread_id, object.delivery_id)
        if not delivery then return missing or failure("NOT_FOUND", "delivery does not exist") end
        local result = apply(tx, head, incarnation, delivery, object)
        if not result.ok or result.replayed then return result end
        return authority.remember(tx, actor, operation, mutation, result.value)
    end)
end
-- Records that the claimant is about to hand the message to its transport,
-- and the acceptance the transport reported, if any.
function M.dispatch(db: sql.DB, actor: string, request: unknown): Result
    return settle("dispatch", {"accepted", "evidence_ref"}, db, actor, request, function(tx: sql.Transaction, head: reader.Head, incarnation: integer, delivery: reader.Delivery, object: {[string]: unknown}): Result
        local refused = require_claimant(delivery, actor, incarnation)
        if refused then return refused end
        if delivery.state ~= "claimed" then return failure("INVALID_STATE", "delivery is not claimed") end
        local accepted: unknown = object.accepted
        if type(accepted) ~= "boolean" then return failure("INVALID_ARGUMENT", "accepted must be a boolean") end
        local evidence, valid = values_optional(object, "evidence_ref")
        if not valid then return failure("INVALID_ARGUMENT", "evidence_ref is not an identifier") end
        local intent_err = transaction.insert_dispatch(tx, delivery.delivery_id, transaction.now(), accepted, evidence)
        if intent_err then return storage(intent_err) end
        if not accepted then return transaction.success({delivery_id = delivery.delivery_id, state = "claimed", dispatched = true}, false) end
        local mark_id, mark_refused = mark(tx, head, actor, delivery, "delivered", evidence, -1)
        if not mark_id then return mark_refused or failure("INTERNAL", "commit failed") end
        local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, "delivered", mark_id, evidence)
        if set_err then return storage(set_err) end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, delivery.message_id, delivery.recipient_id, "delivered", delivery.delivery_id)
        if obligation_err then return storage(obligation_err) end
        return transaction.success({delivery_id = delivery.delivery_id, state = "delivered", mark_record_id = mark_id}, false)
    end)
end
function M.ack(db: sql.DB, actor: string, request: unknown): Result
    return settle("ack", {"evidence_ref"}, db, actor, request, function(tx: sql.Transaction, head: reader.Head, incarnation: integer, delivery: reader.Delivery, object: {[string]: unknown}): Result
        local refused = require_claimant(delivery, actor, incarnation)
        if refused then return refused end
        if delivery.state == "delivered" then return transaction.success({delivery_id = delivery.delivery_id, state = "delivered"}, true) end
        if delivery.state ~= "claimed" then return failure("INVALID_STATE", "delivery is not claimed") end
        local evidence, valid = values_optional(object, "evidence_ref")
        if not valid then return failure("INVALID_ARGUMENT", "evidence_ref is not an identifier") end
        local mark_id, mark_refused = mark(tx, head, actor, delivery, "delivered", evidence, -1)
        if not mark_id then return mark_refused or failure("INTERNAL", "commit failed") end
        local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, "delivered", mark_id, evidence)
        if set_err then return storage(set_err) end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, delivery.message_id, delivery.recipient_id, "delivered", delivery.delivery_id)
        if obligation_err then return storage(obligation_err) end
        return transaction.success({delivery_id = delivery.delivery_id, state = "delivered", mark_record_id = mark_id}, false)
    end)
end
-- Release is allowed only while no dispatch intent exists; afterwards the
-- claim can only become uncertain and be reconciled.
function M.release(db: sql.DB, actor: string, request: unknown): Result
    return settle("release", {"reason"}, db, actor, request, function(tx: sql.Transaction, head: reader.Head, incarnation: integer, delivery: reader.Delivery, object: {[string]: unknown}): Result
        local refused = require_claimant(delivery, actor, incarnation)
        if refused then return refused end
        if delivery.state ~= "claimed" then return failure("INVALID_STATE", "delivery is not claimed") end
        local reason = bounds.id(object.reason)
        if not reason then return failure("INVALID_ARGUMENT", "reason is not an identifier") end
        local dispatched, dispatched_err = reader.dispatched(tx, delivery.delivery_id)
        if dispatched_err then return storage(dispatched_err) end
        if dispatched then return failure("INVALID_STATE", "dispatch intent exists; the claim can only expire and be reconciled") end
        local mark_id, mark_refused = mark(tx, head, actor, delivery, "released", reason, -1)
        if not mark_id then return mark_refused or failure("INTERNAL", "commit failed") end
        local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, "released", mark_id, reason)
        if set_err then return storage(set_err) end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, delivery.message_id, delivery.recipient_id, "pending", nil)
        if obligation_err then return storage(obligation_err) end
        return transaction.success({delivery_id = delivery.delivery_id, state = "released", mark_record_id = mark_id}, false)
    end)
end
-- Expiry is an authority operation: a claim past its lifetime without an
-- acknowledgment becomes uncertain; nothing is reclaimed automatically.
function M.expire(db: sql.DB, actor: string, request: unknown): Result
    return settle("expire", {}, db, actor, request, function(tx: sql.Transaction, head: reader.Head, incarnation: integer, delivery: reader.Delivery, object: {[string]: unknown}): Result
        if not access.may_direct_lifecycle(head.thread_id) and head.owner_actor ~= actor then return failure("DENIED", "only the owner or the lifecycle authority expires claims") end
        if delivery.state == "uncertain" then return transaction.success({delivery_id = delivery.delivery_id, state = "uncertain"}, true) end
        if delivery.state ~= "claimed" then return failure("INVALID_STATE", "delivery is not claimed") end
        if delivery.owner_incarnation == incarnation and delivery.expires_at > transaction.now() then return failure("INVALID_STATE", "the claim has not expired") end
        local mark_id, mark_refused = mark(tx, head, actor, delivery, "uncertain", nil, -1)
        if not mark_id then return mark_refused or failure("INTERNAL", "commit failed") end
        local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, "uncertain", mark_id, nil)
        if set_err then return storage(set_err) end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, delivery.message_id, delivery.recipient_id, "uncertain", delivery.delivery_id)
        if obligation_err then return storage(obligation_err) end
        return transaction.success({delivery_id = delivery.delivery_id, state = "uncertain", mark_record_id = mark_id}, false)
    end)
end
-- Reconciliation decides an uncertain delivery: redeliver, delivered or
-- abandon. The decision is a mark with the deciding actor as producer.
function M.reconcile(db: sql.DB, actor: string, request: unknown): Result
    return settle("reconcile", {"decision", "evidence_ref"}, db, actor, request, function(tx: sql.Transaction, head: reader.Head, incarnation: integer, delivery: reader.Delivery, object: {[string]: unknown}): Result
        if not access.may_direct_lifecycle(head.thread_id) and head.owner_actor ~= actor then return failure("DENIED", "only the owner or the lifecycle authority reconciles") end
        local decision = bounds.member(object.decision, {"redeliver", "delivered", "abandon"})
        if not decision then return failure("INVALID_ARGUMENT", "decision must be redeliver, delivered or abandon") end
        local evidence, valid = values_optional(object, "evidence_ref")
        if not valid then return failure("INVALID_ARGUMENT", "evidence_ref is not an identifier") end
        if delivery.state ~= "uncertain" then return failure("INVALID_STATE", "only an uncertain delivery is reconciled") end
        local delivery_state: record_types.DeliveryState = "released"
        local obligation_state = "pending"
        if decision == "delivered" then
            delivery_state = "delivered"
            obligation_state = "delivered"
        elseif decision == "abandon" then
            obligation_state = "abandoned"
        end
        local mark_id, mark_refused = mark(tx, head, actor, delivery, delivery_state, evidence or decision, -1)
        if not mark_id then return mark_refused or failure("INTERNAL", "commit failed") end
        local set_err = transaction.set_delivery(tx, head.thread_id, delivery.delivery_id, delivery_state, mark_id, evidence or decision)
        if set_err then return storage(set_err) end
        local keep = delivery.delivery_id
        if obligation_state == "pending" then keep = nil end
        local obligation_err = transaction.set_obligation(tx, head.thread_id, delivery.message_id, delivery.recipient_id, obligation_state, keep)
        if obligation_err then return storage(obligation_err) end
        return transaction.success({delivery_id = delivery.delivery_id, state = delivery_state, obligation = obligation_state, mark_record_id = mark_id}, false)
    end)
end
return M

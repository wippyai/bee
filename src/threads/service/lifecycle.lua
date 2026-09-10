-- MIT. Work lifecycle: admission, attempts, turns and terminal receipts.
-- Only a caller the host granted lifecycle authority commits these; every
-- transition is checked against the indexes in the same transaction.
local sql = require("sql")
local bounds = require("bounds")
local values = require("values")
local decoders = require("lifecycle")
local record_types = require("record_types")
local access = require("access")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local M = {}
type Result = transaction.Result
type Prepared = {mutation: authority.Mutation, object: {[string]: unknown}}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
local function prepare(request: unknown, fields: {string}): (Prepared?, Result?)
    local mutation, invalid = authority.mutation(request)
    if not mutation then return nil, invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local allowed: {string} = {"thread_id", "idempotency_key", "causation", "correlation_id"}
    for _, name in ipairs(fields) do allowed[#allowed + 1] = name end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return nil, failure("INVALID_ARGUMENT", unknown_field) end
    if not access.may_direct_lifecycle(mutation.thread_id) then return nil, failure("DENIED", "caller holds no lifecycle authority for the thread") end
    return {mutation = mutation, object = object}, nil
end
-- A caller naming a carrier_epoch must hold the attempt's current epoch;
-- a stale carrier cannot settle turns, open turns or commit receipts.
local function fenced(tx: sql.Transaction, thread_id: string, attempt_id: string, object: {[string]: unknown}): Result?
    if object.carrier_epoch == nil then return nil end
    local epoch = bounds.integer(object.carrier_epoch)
    if not epoch or epoch < 1 then return failure("INVALID_ARGUMENT", "carrier_epoch must be a positive integer") end
    local rows, err = tx:query("SELECT carrier_epoch FROM bee_thread_carriers WHERE thread_id = ? AND attempt_id = ?", {thread_id, attempt_id})
    if err or not rows then return storage("read carrier epoch") end
    if #rows == 0 then return failure("CONFLICT", "no carrier has claimed the attempt") end
    local current = rows[1].carrier_epoch
    if current ~= epoch then return failure("CONFLICT", "carrier epoch " .. tostring(epoch) .. " is not current") end
    return nil
end
local function required(object: {[string]: unknown}, name: string): (string?, Result?)
    local id = bounds.id(object[name])
    if not id then return nil, failure("INVALID_ARGUMENT", name .. " is not an identifier") end
    return id, nil
end
-- Opens the thread for a lifecycle write: head present and open, and no
-- stored reply for this key. Returns the replay when there is one.
local function open_thread(tx: sql.Transaction, actor: string, operation: string, prepared: Prepared): (reader.Head?, authority.Context?, Result?)
    local head, head_err = reader.head(tx, prepared.mutation.thread_id)
    if head_err then return nil, nil, storage(head_err) end
    if not head then return nil, nil, failure("NOT_FOUND", "thread does not exist") end
    local replayed, replay_err = authority.replay(tx, actor, operation, prepared.mutation)
    if replay_err then return nil, nil, storage(replay_err) end
    if replayed then return nil, nil, replayed end
    if head.state ~= "open" then return nil, nil, failure("INVALID_STATE", "thread is closed") end
    local context: authority.Context = {}
    local correlation, valid = values.optional_id(prepared.object, "correlation_id")
    if not valid then return nil, nil, failure("INVALID_ARGUMENT", "correlation_id is not an identifier") end
    context.correlation_id = correlation
    if prepared.object.causation ~= nil then
        local ref, ref_error = values.ref(prepared.object.causation)
        if not ref then return nil, nil, failure("INVALID_ARGUMENT", "causation: " .. tostring(ref_error)) end
        if ref.thread_id ~= head.thread_id then return nil, nil, failure("INVALID_ARGUMENT", "causation must reference this thread") end
        local cause, cause_err = reader.record(tx, head.thread_id, ref.record_id)
        if cause_err then return nil, nil, storage(cause_err) end
        if not cause then return nil, nil, failure("INVALID_ARGUMENT", "causation record does not exist") end
        context.causation = ref
    end
    return head, context, nil
end
function M.admit_action(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "admitted"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing = required(prepared.object, "action_id")
    if not action_id then return missing or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local admitted, decode_error = decoders.admitted(prepared.object.admitted)
    if not admitted then return failure("INVALID_ARGUMENT", "admitted: " .. tostring(decode_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "admit_action", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local existing, existing_err = reader.action(tx, head.thread_id, action_id)
        if existing_err then return storage(existing_err) end
        if existing then return failure("CONFLICT", "action already exists") end
        local count, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_actions WHERE thread_id = ?", {head.thread_id}, "actions")
        if not count then return storage(count_err or "count actions") end
        if count >= bounds.MAX_THREAD_ACTIONS then return failure("LIMIT_EXCEEDED", "thread action limit reached") end
        context.action_id = action_id
        local committed, refused = authority.commit_record(tx, head, "action.admitted", actor, "bee", admitted, context, nil, nil, 1)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local index_err = transaction.insert_action(tx, head.thread_id, action_id, committed.record_id)
        if index_err then return storage(index_err) end
        return authority.remember(tx, actor, "admit_action", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, action_id = action_id, state = "admitted"})
    end)
end
-- prepare_attempt: the attempt exists with its pinned execution plan before
-- anything external does. One live attempt per action.
function M.prepare_attempt(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "attempt_id", "prepared"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing_action = required(prepared.object, "action_id")
    if not action_id then return missing_action or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local attempt_id, missing_attempt = required(prepared.object, "attempt_id")
    if not attempt_id then return missing_attempt or failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    local plan, decode_error = decoders.prepared(prepared.object.prepared)
    if not plan then return failure("INVALID_ARGUMENT", "prepared: " .. tostring(decode_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "prepare_attempt", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local action, action_err = reader.action(tx, head.thread_id, action_id)
        if action_err then return storage(action_err) end
        if not action then return failure("NOT_FOUND", "action does not exist") end
        if action.state == "ended" then return failure("INVALID_STATE", "action has ended") end
        local existing, existing_err = reader.attempt(tx, head.thread_id, attempt_id)
        if existing_err then return storage(existing_err) end
        if existing then return failure("CONFLICT", "attempt already exists") end
        local live, live_err = reader.running_attempt(tx, head.thread_id, action_id)
        if live_err then return storage(live_err) end
        if live then return failure("INVALID_STATE", "action already has a live attempt") end
        local count, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_attempts WHERE thread_id = ?", {head.thread_id}, "attempts")
        if not count then return storage(count_err or "count attempts") end
        if count >= bounds.MAX_THREAD_ATTEMPTS then return failure("LIMIT_EXCEEDED", "thread attempt limit reached") end
        context.action_id = action_id
        context.attempt_id = attempt_id
        local committed, refused = authority.commit_record(tx, head, "attempt.prepared", actor, "bee", plan, context, nil, nil, 2)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local index_err = transaction.insert_attempt(tx, head.thread_id, attempt_id, action_id, committed.record_id)
        if index_err then return storage(index_err) end
        return authority.remember(tx, actor, "prepare_attempt", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, attempt_id = attempt_id})
    end)
end
-- start_attempt: a prepared attempt becomes running under a new owner
-- epoch, from the placement's recorded execution identity.
function M.start_attempt(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "attempt_id", "started"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing_action = required(prepared.object, "action_id")
    if not action_id then return missing_action or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local attempt_id, missing_attempt = required(prepared.object, "attempt_id")
    if not attempt_id then return missing_attempt or failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    local started, decode_error = decoders.started(prepared.object.started)
    if not started then return failure("INVALID_ARGUMENT", "started: " .. tostring(decode_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "start_attempt", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local action, action_err = reader.action(tx, head.thread_id, action_id)
        if action_err then return storage(action_err) end
        if not action then return failure("NOT_FOUND", "action does not exist") end
        if action.state == "ended" then return failure("INVALID_STATE", "action has ended") end
        local attempt, attempt_err = reader.attempt(tx, head.thread_id, attempt_id)
        if attempt_err then return storage(attempt_err) end
        if not attempt then return failure("NOT_FOUND", "attempt does not exist") end
        if attempt.action_id ~= action_id then return failure("INVALID_ARGUMENT", "attempt does not belong to the action") end
        if attempt.state ~= "prepared" then return failure("INVALID_STATE", "attempt is " .. attempt.state .. ", not prepared") end
        local highest, highest_err = reader.highest_epoch(tx, head.thread_id, action_id)
        if not highest then return storage(highest_err or "read attempt epochs") end
        if started.owner_epoch <= highest then return failure("INVALID_STATE", "owner_epoch must exceed every earlier attempt of the action") end
        context.action_id = action_id
        context.attempt_id = attempt_id
        local committed, refused = authority.commit_record(tx, head, "attempt.started", actor, "bee", started, context, nil, nil, 0)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local index_err = transaction.start_attempt(tx, head.thread_id, attempt_id, started.owner_epoch, committed.record_id)
        if index_err then return storage(index_err) end
        local state_err = transaction.set_action_state(tx, head.thread_id, action_id, "running")
        if state_err then return storage(state_err) end
        return authority.remember(tx, actor, "start_attempt", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, attempt_id = attempt_id, owner_epoch = started.owner_epoch})
    end)
end
local function running_attempt_of(tx: sql.Transaction, thread_id: string, action_id: string, attempt_id: string): (reader.Attempt?, Result?)
    local attempt, attempt_err = reader.attempt(tx, thread_id, attempt_id)
    if attempt_err then return nil, storage(attempt_err) end
    if not attempt then return nil, failure("NOT_FOUND", "attempt does not exist") end
    if attempt.action_id ~= action_id then return nil, failure("INVALID_ARGUMENT", "attempt does not belong to the action") end
    if attempt.state == "ended" then return nil, failure("INVALID_STATE", "attempt has ended") end
    return attempt, nil
end
function M.request_turn(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "attempt_id", "turn_id", "turn", "carrier_epoch"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing_action = required(prepared.object, "action_id")
    if not action_id then return missing_action or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local attempt_id, missing_attempt = required(prepared.object, "attempt_id")
    if not attempt_id then return missing_attempt or failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    local turn_id, missing_turn = required(prepared.object, "turn_id")
    if not turn_id then return missing_turn or failure("INVALID_ARGUMENT", "turn_id is not an identifier") end
    local turn, decode_error = decoders.turn_request(prepared.object.turn)
    if not turn then return failure("INVALID_ARGUMENT", "turn: " .. tostring(decode_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "request_turn", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local attempt, refused_attempt = running_attempt_of(tx, head.thread_id, action_id, attempt_id)
        if not attempt then return refused_attempt or failure("INTERNAL", "attempt unavailable") end
        local stale = fenced(tx, head.thread_id, attempt_id, prepared.object)
        if stale then return stale end
        local existing, existing_err = reader.turn(tx, head.thread_id, turn_id)
        if existing_err then return storage(existing_err) end
        if existing then return failure("CONFLICT", "turn already exists") end
        local open, open_err = reader.open_turn(tx, head.thread_id, attempt_id)
        if open_err then return storage(open_err) end
        if open then return failure("INVALID_STATE", "attempt already has an open turn") end
        local count, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_turns WHERE thread_id = ?", {head.thread_id}, "turns")
        if not count then return storage(count_err or "count turns") end
        if count >= bounds.MAX_THREAD_TURNS then return failure("LIMIT_EXCEEDED", "thread turn limit reached") end
        context.action_id = action_id
        context.attempt_id = attempt_id
        context.turn_id = turn_id
        local committed, refused = authority.commit_record(tx, head, "turn.request", actor, "bee", turn, context, nil, nil, 1)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local index_err = transaction.insert_turn(tx, head.thread_id, turn_id, action_id, attempt_id, committed.record_id)
        if index_err then return storage(index_err) end
        return authority.remember(tx, actor, "request_turn", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, turn_id = turn_id})
    end)
end
function M.end_turn(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "attempt_id", "turn_id", "turn_end", "carrier_epoch"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing_action = required(prepared.object, "action_id")
    if not action_id then return missing_action or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local attempt_id, missing_attempt = required(prepared.object, "attempt_id")
    if not attempt_id then return missing_attempt or failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    local turn_id, missing_turn = required(prepared.object, "turn_id")
    if not turn_id then return missing_turn or failure("INVALID_ARGUMENT", "turn_id is not an identifier") end
    local turn_end, decode_error = decoders.turn_end(prepared.object.turn_end)
    if not turn_end then return failure("INVALID_ARGUMENT", "turn_end: " .. tostring(decode_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "end_turn", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local turn, turn_err = reader.turn(tx, head.thread_id, turn_id)
        if turn_err then return storage(turn_err) end
        if not turn then return failure("NOT_FOUND", "turn does not exist") end
        if turn.action_id ~= action_id or turn.attempt_id ~= attempt_id then return failure("INVALID_ARGUMENT", "turn does not belong to the attempt") end
        if turn.ended then return failure("CONFLICT", "turn has already ended") end
        local attempt, refused_attempt = running_attempt_of(tx, head.thread_id, action_id, attempt_id)
        if not attempt then return refused_attempt or failure("INTERNAL", "attempt unavailable") end
        local stale = fenced(tx, head.thread_id, attempt_id, prepared.object)
        if stale then return stale end
        context.action_id = action_id
        context.attempt_id = attempt_id
        context.turn_id = turn_id
        local committed, refused = authority.commit_record(tx, head, "turn.end", actor, "bee", turn_end, context, nil, nil, -1)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local index_err = transaction.end_turn(tx, head.thread_id, turn_id, committed.record_id)
        if index_err then return storage(index_err) end
        return authority.remember(tx, actor, "end_turn", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, turn_id = turn_id, outcome = turn_end.outcome})
    end)
end
function M.receipt(db: sql.DB, actor: string, request: unknown): Result
    local prepared, invalid = prepare(request, {"action_id", "attempt_id", "receipt", "carrier_epoch"})
    if not prepared then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local action_id, missing_action = required(prepared.object, "action_id")
    if not action_id then return missing_action or failure("INVALID_ARGUMENT", "action_id is not an identifier") end
    local attempt_id, attempt_valid = values.optional_id(prepared.object, "attempt_id")
    if not attempt_valid then return failure("INVALID_ARGUMENT", "attempt_id is not an identifier") end
    local receipt, decode_error = decoders.receipt(prepared.object.receipt)
    if not receipt then return failure("INVALID_ARGUMENT", "receipt: " .. tostring(decode_error)) end
    if (receipt.scope == "attempt") ~= (attempt_id ~= nil) then return failure("INVALID_ARGUMENT", "an attempt receipt names its attempt_id and an action receipt names none") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, context, stop = open_thread(tx, actor, "receipt", prepared)
        if not head or not context then return stop or failure("INTERNAL", "thread unavailable") end
        local action, action_err = reader.action(tx, head.thread_id, action_id)
        if action_err then return storage(action_err) end
        if not action then return failure("NOT_FOUND", "action does not exist") end
        context.action_id = action_id
        if receipt.scope == "attempt" and attempt_id then
            local attempt, attempt_err = reader.attempt(tx, head.thread_id, attempt_id)
            if attempt_err then return storage(attempt_err) end
            if not attempt then return failure("NOT_FOUND", "attempt does not exist") end
            if attempt.action_id ~= action_id then return failure("INVALID_ARGUMENT", "attempt does not belong to the action") end
            if attempt.state == "ended" then return failure("CONFLICT", "attempt already has a receipt") end
            local stale = fenced(tx, head.thread_id, attempt_id, prepared.object)
            if stale then return stale end
            local open, open_err = reader.open_turn(tx, head.thread_id, attempt_id)
            if open_err then return storage(open_err) end
            if open then return failure("INVALID_STATE", "attempt has an open turn") end
            context.attempt_id = attempt_id
            local committed, refused = authority.commit_record(tx, head, "receipt", actor, "bee", receipt, context, nil, nil, -1)
            if not committed then return refused or failure("INTERNAL", "commit failed") end
            local settle_err = transaction.insert_settlement(tx, head.thread_id, "attempt", action_id, attempt_id, receipt.outcome, committed.record_id)
            if settle_err then return storage(settle_err) end
            local attempt_state_err = transaction.set_attempt_state(tx, head.thread_id, attempt_id, "ended")
            if attempt_state_err then return storage(attempt_state_err) end
            local action_state_err = transaction.set_action_state(tx, head.thread_id, action_id, "admitted")
            if action_state_err then return storage(action_state_err) end
            return authority.remember(tx, actor, "receipt", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, scope = "attempt", attempt_id = attempt_id, outcome = receipt.outcome})
        end
        if action.state == "ended" then return failure("CONFLICT", "action already has a receipt") end
        local live, live_err = reader.running_attempt(tx, head.thread_id, action_id)
        if live_err then return storage(live_err) end
        if live then return failure("INVALID_STATE", "action has a running attempt") end
        local committed, refused = authority.commit_record(tx, head, "receipt", actor, "bee", receipt, context, nil, nil, -1)
        if not committed then return refused or failure("INTERNAL", "commit failed") end
        local settle_err = transaction.insert_settlement(tx, head.thread_id, "action", action_id, nil, receipt.outcome, committed.record_id)
        if settle_err then return storage(settle_err) end
        local state_err = transaction.set_action_state(tx, head.thread_id, action_id, "ended")
        if state_err then return storage(state_err) end
        return authority.remember(tx, actor, "receipt", prepared.mutation, {record_id = committed.record_id, sequence = committed.sequence, scope = "action", outcome = receipt.outcome})
    end)
end
return M

-- MIT. One-shot notices. A member asks the owner to tell it once, on its own
-- thread, when an action it may read ends a turn or an attempt. The owner
-- commits that notification after the ending record lands, under the
-- watcher's own identity and the notice's key, so a repeated check or a
-- replayed registration never tells twice. A watcher that can no longer
-- receive on its thread has its notice cancelled rather than delivered.
local sql = require("sql")
local uuid = require("uuid")
local bounds = require("bounds")
local record = require("record")
local message = require("message")
local record_types = require("record_types")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local access = require("access")
local M = {}
type Result = transaction.Result
type Ending = {what: "turn" | "exit", outcome: record_types.Outcome?}
M.MAX_PENDING_PER_WATCHER = 64
M.SCAN_RECORDS = 256
M.MAX_NOTICES_PER_PASS = 64
local function failure(code: string, message_text: string): Result
    return transaction.failure(code, message_text)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
-- Whether a committed record ends a turn or an attempt of its action: a
-- turn.end or a stream turn signal that ended closes a turn; a receipt or an
-- observed execution exit closes the attempt. Pure.
function M.ending(stored: record_types.Record): Ending?
    if stored.kind == "turn.end" then
        return {what = "turn", outcome = (stored.body :: record_types.TurnEnd).outcome}
    end
    if stored.kind == "receipt" then
        return {what = "exit", outcome = (stored.body :: record_types.Receipt).outcome}
    end
    if stored.kind ~= "observation" then return nil end
    local data = (stored.body :: record_types.Observation).data
    if data.type == "turn.signal" then
        local signal = data :: record_types.TurnSignal
        if signal.phase == "ended" then return {what = "turn", outcome = signal.reported_outcome} end
        return nil
    end
    if data.type == "execution.exit" then return {what = "exit", outcome = nil} end
    return nil
end
local function text_of(action_id: string, ending: Ending): string
    if ending.what == "turn" then return "Action " .. action_id .. " ended its turn." end
    return "Action " .. action_id .. " exited."
end
-- Commits the notification on the watcher's thread, or cancels the notice
-- when the watcher can no longer receive there. Returns the watcher thread
-- when a record was committed.
local function deliver(tx: sql.Transaction, notice: reader.Notice, cause: record_types.Record, ending: Ending): (string?, Result?)
    local head, head_err = reader.head(tx, notice.watcher_thread_id)
    if head_err then return nil, storage(head_err) end
    local member, member_err = reader.member(tx, notice.watcher_thread_id, notice.watcher_actor)
    if member_err then return nil, storage(member_err) end
    if not head or head.state ~= "open" or not member or not member.active or not access.submits(member.role) then
        local cancel_err = transaction.cancel_notice(tx, notice.notice_id)
        if cancel_err then return nil, storage(cancel_err) end
        return nil, nil
    end
    local target_action = notice.target_action_id or cause.action_id or notice.target_attempt_id or "unknown"
    local body: {[string]: unknown} = {message_id = "notice:" .. notice.notice_id, message_kind = "notification", sender_id = notice.watcher_actor,
        recipient_ids = {notice.watcher_actor}, content = {text = text_of(target_action, ending)}}
    if notice.watcher_action_id then body.recipient_action_ids = {notice.watcher_action_id} end
    if ending.outcome then body.outcome = ending.outcome end
    local decoded, decode_error = message.decode(body)
    if not decoded then return nil, failure("INTERNAL", "notice message: " .. tostring(decode_error)) end
    local context: authority.Context = {causation = {thread_id = cause.thread_id, record_id = cause.record_id}}
    local committed = authority.project_message(tx, head, notice.watcher_actor, decoded, context, "notice/" .. notice.watcher_actor, notice.notice_id)
    if not committed.ok then return nil, committed end
    local value = committed.value :: {record_id: string}
    local fire_err = transaction.fire_notice(tx, notice.notice_id, value.record_id)
    if fire_err then return nil, storage(fire_err) end
    return notice.watcher_thread_id, nil
end
-- Scans the target action's records after the notice's cursor; the first
-- ending record delivers the notice, otherwise the cursor advances past
-- what was scanned.
local function settle(tx: sql.Transaction, notice: reader.Notice): (string?, Result?)
    if notice.target_attempt_id and not notice.target_action_id then
        local attempt, attempt_err = reader.attempt(tx, notice.target_thread_id, notice.target_attempt_id)
        if attempt_err then return nil, storage(attempt_err) end
        if not attempt then
            local target_head, head_err = reader.head(tx, notice.target_thread_id)
            if head_err then return nil, storage(head_err) end
            if not target_head or target_head.state ~= "open" then
                local cancel_err = transaction.cancel_notice(tx, notice.notice_id)
                if cancel_err then return nil, storage(cancel_err) end
            end
            return nil, nil
        end
        local bind_err = transaction.bind_notice_attempt(tx, notice.notice_id, attempt.action_id)
        if bind_err then return nil, storage(bind_err) end
        notice.target_action_id = attempt.action_id
    end
    local attempt_id = notice.target_attempt_id
    local action_id = notice.target_action_id
    if not attempt_id and not action_id then return nil, failure("INTERNAL", "a pending notice has no target") end
    local after = notice.after_sequence
    while true do
        local rows, rows_err
        if attempt_id then
            rows, rows_err = reader.attempt_records(tx, notice.target_thread_id, attempt_id, after, M.SCAN_RECORDS)
        else
            rows, rows_err = reader.action_records(tx, notice.target_thread_id, action_id :: string, after, M.SCAN_RECORDS)
        end
        if not rows then return nil, storage(rows_err or "read notice target records") end
        for _, row in ipairs(rows) do
            local stored, stored_error = record.decode_json(row.record_json)
            if not stored then return nil, failure("INTERNAL", stored_error or "stored record is corrupt") end
            local ending = M.ending(stored)
            if ending then return deliver(tx, notice, stored, ending) end
            after = row.sequence
        end
        if #rows < M.SCAN_RECORDS then break end
    end
    if after ~= notice.after_sequence then
        local advance_err = transaction.advance_notice(tx, notice.notice_id, after)
        if advance_err then return nil, storage(advance_err) end
    end
    return nil, nil
end
-- fire: settles pending notices that watch actions on one thread, or on
-- every thread when none is named, in one owner transaction. Runs after a
-- commit on the target thread and when the owner starts; the caller wakes
-- the returned watcher threads.
function M.fire(db: sql.DB, target_thread_id: string?): ({string}?, string?)
    -- Most commits watch nothing; a read decides that without taking the
    -- store's write lock.
    local waiting = transaction.read(db, function(tx: sql.Transaction): Result
        local pending, pending_err = reader.pending_notices(tx, target_thread_id, 1)
        if not pending then return storage(pending_err or "read pending notices") end
        return transaction.success(#pending > 0, false)
    end)
    if not waiting.ok then return nil, waiting.message or "read pending notices" end
    if waiting.value ~= true then return {}, nil end
    local woken: {string} = {}
    local result = transaction.write(db, function(tx: sql.Transaction): Result
        woken = {}
        local seen: {[string]: boolean} = {}
        local pending, pending_err = reader.pending_notices(tx, target_thread_id, M.MAX_NOTICES_PER_PASS)
        if not pending then return storage(pending_err or "read pending notices") end
        for _, notice in ipairs(pending) do
            local watcher_thread, stop = settle(tx, notice)
            if stop then return stop end
            if watcher_thread and not seen[watcher_thread] then
                seen[watcher_thread] = true
                woken[#woken + 1] = watcher_thread
            end
        end
        return transaction.success(nil, false)
    end)
    if not result.ok then return nil, result.message or "fire notices" end
    return woken, nil
end
-- notify: registers a notice on the caller's own thread for an action of a
-- thread the caller may read. The recipient action, when named, must be
-- the caller's own action on its thread. An action with no live attempt
-- has already ended, so its latest settlement is delivered at once.
function M.notify(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    -- caller_node_id is the authenticated caller attestation a forwarded
    -- request carries; the admission already verified it, and the owner
    -- accepts it so a cross-node notice is not rejected for naming its caller.
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "target_thread_id", "target_action_id", "target_attempt_id", "watcher_action_id", "caller_node_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    if object.caller_node_id ~= nil and not bounds.id(object.caller_node_id) then
        return failure("INVALID_ARGUMENT", "caller_node_id is not an identifier")
    end
    local target_thread_id = bounds.id(object.target_thread_id)
    local target_action_id = object.target_action_id ~= nil and bounds.id(object.target_action_id) or nil
    local target_attempt_id = object.target_attempt_id ~= nil and bounds.id(object.target_attempt_id) or nil
    if not target_thread_id then return failure("INVALID_ARGUMENT", "target_thread_id is not an identifier") end
    if (object.target_action_id ~= nil and not target_action_id) or (object.target_attempt_id ~= nil and not target_attempt_id) then
        return failure("INVALID_ARGUMENT", "target action or attempt is not an identifier")
    end
    if (target_action_id == nil) == (target_attempt_id == nil) then
        return failure("INVALID_ARGUMENT", "name exactly one target_action_id or target_attempt_id")
    end
    local watcher_action_id: string? = nil
    if object.watcher_action_id ~= nil then
        watcher_action_id = bounds.id(object.watcher_action_id)
        if not watcher_action_id then return failure("INVALID_ARGUMENT", "watcher_action_id is not an identifier") end
    end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "notify", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if not access.submits(caller.role) then return failure("DENIED", "an observer receives no notices on this thread") end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        if watcher_action_id then
            local action, action_err = reader.action(tx, head.thread_id, watcher_action_id)
            if action_err then return storage(action_err) end
            if not action then return failure("INVALID_ARGUMENT", "watcher_action_id is not an action of the thread") end
            local own, own_refused = authority.admitted_for(tx, watcher_action_id, actor)
            if own_refused then return own_refused end
            if not own then return failure("DENIED", "watcher_action_id is not an action admitted for the caller") end
        end
        local target, reader_member, target_denied = authority.membership(tx, target_thread_id, actor)
        if not target or not reader_member then return target_denied or failure("DENIED", "caller is not a member of the target thread") end
        local attempt: reader.Attempt? = nil
        if target_action_id then
            local action, action_err = reader.action(tx, target_thread_id, target_action_id)
            if action_err then return storage(action_err) end
            if not action then return failure("NOT_FOUND", "the target action does not exist") end
        elseif target_attempt_id then
            local found, attempt_err = reader.attempt(tx, target_thread_id, target_attempt_id)
            if attempt_err then return storage(attempt_err) end
            attempt = found
            if attempt then target_action_id = attempt.action_id end
        end
        local pending_count, count_err = reader.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_notices WHERE watcher_thread_id = ? AND state = 'pending'", {head.thread_id}, "pending notices")
        if not pending_count then return storage(count_err or "count pending notices") end
        if pending_count >= M.MAX_PENDING_PER_WATCHER then return failure("LIMIT_EXCEEDED", "the thread already waits on " .. tostring(M.MAX_PENDING_PER_WATCHER) .. " notices") end
        local notice_id, id_err = uuid.v7()
        if id_err or not notice_id then return failure("INTERNAL", "allocate notice identifier") end
        local insert_err = transaction.insert_notice(tx, notice_id, actor, head.thread_id, watcher_action_id, target_thread_id,
            target_action_id, target_attempt_id, target.head_sequence, transaction.now())
        if insert_err then return storage(insert_err) end
        local value: {[string]: unknown} = {notice_id = notice_id, state = "pending", target_thread_id = target_thread_id}
        if target_action_id then value.target_action_id = target_action_id end
        if target_attempt_id then value.target_attempt_id = target_attempt_id end
        local should_settle = false
        if target_attempt_id then
            should_settle = attempt ~= nil and attempt.state == "ended"
        elseif target_action_id then
            local live, live_err = reader.running_attempt(tx, target_thread_id, target_action_id)
            if live_err then return storage(live_err) end
            should_settle = live == nil
        end
        if should_settle and target_action_id then
            local settled, settled_err
            if target_attempt_id then
                settled, settled_err = reader.settled(tx, target_thread_id, "attempt", target_action_id, target_attempt_id)
            else
                settled, settled_err = reader.latest_settlement(tx, target_thread_id, target_action_id)
            end
            if settled_err then return storage(settled_err) end
            if settled then
                local stored, stored_error = record.decode_json(settled.record_json)
                if not stored then return failure("INTERNAL", stored_error or "stored record is corrupt") end
                local ending = M.ending(stored)
                if not ending then return failure("INTERNAL", "a settlement record ends no attempt") end
                local notice, notice_err = reader.notice(tx, notice_id)
                if not notice then return storage(notice_err or "read thread notice") end
                local delivered, stop = deliver(tx, notice, stored, ending)
                if stop then return stop end
                if delivered then value.state = "fired" end
            end
        end
        return authority.remember(tx, actor, "notify", mutation, value)
    end)
end
return M

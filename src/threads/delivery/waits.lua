-- MIT. thread_wait: check, subscribe to the thread's commit events, check
-- again, wait for an event or the deadline, and check once more before
-- reporting a timeout (commits.await). No transaction spans a wait; an event is a hint that
-- the check decides.
local sql = require("sql")
local commits = require("commits")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local canonical = require("canonical")
local record = require("record")
local record_types = require("record_types")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local claims = require("claims")
local M = {}
type Result = transaction.Result
type Wait = {thread_id: string, consumer_id: string, after: integer, limit: integer, wait_ms: integer, turn_id: string?, attempt_id: string?}
local SCAN_WINDOW = 1024
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
-- Phase A: one transaction that claims what is pending and pages what is
-- new. Only a nonempty outcome is remembered under the wait's key.
local function check(db: sql.DB, actor: string, mutation: authority.Mutation, wait: Wait, digest: string, final: boolean): Result
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, incarnation, stop = claims.open_for_claim(tx, actor, "wait", mutation)
        if not head or not incarnation then return stop or failure("INTERNAL", "thread unavailable") end
        local batch, refused = claims.claim_pending(tx, head, actor, incarnation, wait.consumer_id, "wait", wait.limit, mutation.idempotency_key, digest, wait.turn_id, wait.attempt_id)
        if not batch then return refused or failure("INTERNAL", "claim failed") end
        local window_end = math.floor(math.min(wait.after + SCAN_WINDOW, head.head_sequence))
        local rows, rows_err = reader.page(tx, head.thread_id, wait.after, window_end, wait.limit, nil, nil)
        if not rows then return storage(rows_err or "read thread records") end
        local records: {record_types.Record} = {}
        for index = 1, math.min(#rows, wait.limit) do
            local decoded, decode_error = record.decode_json(rows[index].record_json)
            if not decoded then return failure("INTERNAL", decode_error or "stored record is corrupt") end
            records[index] = decoded
        end
        local has_more = #rows > wait.limit
        local scanned_through = window_end
        if has_more then scanned_through = records[#records].sequence end
        if not has_more and window_end < head.head_sequence then has_more = true end
        local value: {[string]: unknown} = {status = "ready", batch_id = batch.batch_id, deliveries = batch.deliveries, owner_incarnation = incarnation,
            expires_at = batch.expires_at, records = records, scanned_through = scanned_through, has_more = has_more}
        if #batch.deliveries > 0 or #records > 0 or has_more then
            return authority.remember(tx, actor, "wait", mutation, value)
        end
        if final then
            value.status = "timeout"
            return authority.remember(tx, actor, "wait", mutation, value)
        end
        value.status = "empty"
        return transaction.success(value, false)
    end)
end
local function pending(result: Result): boolean
    return result.ok and not result.replayed and type(result.value) == "table" and (result.value).status == "empty"
end
-- Phase A for a read-only change-wait: one read transaction that reports
-- whether the thread has moved past the caller's cursor. It claims
-- nothing and writes nothing; a viewer learns only that there is more to
-- page, never taking an obligation.
local function watch_check(db: sql.DB, actor: string, thread_id: string, after: integer): Result
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local ready = head.head_sequence > after
        return transaction.success({status = ready and "ready" or "empty", scanned_through = after, head_sequence = head.head_sequence}, false)
    end)
end
local function watch_pending(result: Result): boolean
    return result.ok and type(result.value) == "table" and (result.value).status == "empty"
end
local function watch_final(result: Result): Result
    if not result.ok then return result end
    local value = result.value
    if value.status == "empty" then value.status = "timeout" end
    return result
end
local function await(thread_id: string, wait_ms: integer, pending: (Result) -> boolean, check: (boolean) -> Result): Result
    return commits.await({thread_id}, wait_ms, pending, check, function(message: string): Result
        return failure("INTERNAL", message)
    end)
end
-- watch: a bounded, read-only wait for the thread to move past a cursor. It
-- hears the same commit events as wait, but every check is a read and no
-- obligation is ever claimed, so a viewer's reading leaves delivery state and
-- history unchanged.
function M.watch(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    -- caller_node_id is the node the Threads service authenticated for a
    -- forwarded request.
    local unknown_field = bounds.fields(object, {"thread_id", "after_sequence", "wait_ms", "transport_budget_ms", "caller_node_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    if object.caller_node_id ~= nil and not bounds.id(object.caller_node_id) then
        return failure("INVALID_ARGUMENT", "caller_node_id is not an identifier")
    end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    local after = record_bounds.cursor(object.after_sequence)
    if not after then return failure("INVALID_ARGUMENT", "after_sequence must be between 0 and " .. tostring(record_bounds.MAX_THREAD_RECORDS)) end
    local wait_ms = bounds.integer(object.wait_ms)
    if not wait_ms or wait_ms < 0 then return failure("INVALID_ARGUMENT", "wait_ms must be a nonnegative integer") end
    local budget: integer? = nil
    if object.transport_budget_ms ~= nil then
        local number = bounds.integer(object.transport_budget_ms)
        if not number or number < 0 then return failure("INVALID_ARGUMENT", "transport_budget_ms must be a nonnegative integer") end
        budget = number
    end
    local effective = commits.effective_wait(wait_ms, budget)
    local first = watch_check(db, actor, thread_id, after)
    if not watch_pending(first) or effective == 0 then return watch_final(first) end
    return watch_final(await(thread_id, effective, watch_pending, function(_final: boolean): Result
        return watch_check(db, actor, thread_id, after)
    end))
end
function M.wait(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "consumer_id", "after_sequence", "limit", "wait_ms", "transport_budget_ms", "turn_id", "attempt_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local consumer_id = bounds.id(object.consumer_id)
    if not consumer_id then return failure("INVALID_ARGUMENT", "consumer_id is not an identifier") end
    local after = record_bounds.cursor(object.after_sequence)
    if not after then return failure("INVALID_ARGUMENT", "after_sequence must be between 0 and " .. tostring(record_bounds.MAX_THREAD_RECORDS)) end
    local limit = record_bounds.page_limit(object.limit)
    if not limit then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(record_bounds.MAX_PAGE_RECORDS)) end
    local wait_ms = bounds.integer(object.wait_ms)
    if not wait_ms or wait_ms < 0 then return failure("INVALID_ARGUMENT", "wait_ms must be a nonnegative integer") end
    local budget: integer? = nil
    if object.transport_budget_ms ~= nil then
        local number = bounds.integer(object.transport_budget_ms)
        if not number or number < 0 then return failure("INVALID_ARGUMENT", "transport_budget_ms must be a nonnegative integer") end
        budget = number
    end
    local turn_id: string? = nil
    local attempt_id: string? = nil
    if object.turn_id ~= nil or object.attempt_id ~= nil then
        turn_id, attempt_id = bounds.id(object.turn_id), bounds.id(object.attempt_id)
        if not turn_id or not attempt_id then return failure("INVALID_ARGUMENT", "turn_id and attempt_id come together") end
    end
    local wait: Wait = {thread_id = mutation.thread_id, consumer_id = consumer_id, after = after, limit = limit, wait_ms = commits.effective_wait(wait_ms, budget), turn_id = turn_id, attempt_id = attempt_id}
    local digest, digest_error = canonical.encode({consumer_id = consumer_id, limit = limit, channel = "wait", turn_id = turn_id, attempt_id = attempt_id})
    if not digest then return failure("INVALID_ARGUMENT", digest_error or "request is not encodable") end
    local first = check(db, actor, mutation, wait, digest, wait.wait_ms == 0)
    if not pending(first) then return first end
    return await(wait.thread_id, wait.wait_ms, pending, function(final: boolean): Result
        return check(db, actor, mutation, wait, digest, final)
    end)
end
return M

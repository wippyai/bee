-- MIT. thread_wait: check, register with the waiter, check again, wait for a
-- wakeup or the deadline, and check once more before reporting a timeout.
-- No transaction spans a wait; a wakeup is a hint that the check decides.
local sql = require("sql")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local bounds = require("bounds")
local canonical = require("canonical")
local record = require("record")
local record_types = require("record_types")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local claims = require("claims")
local M = {}
type Result = transaction.Result
type Channel = channel.Channel
type Wait = {thread_id: string, consumer_id: string, after: integer, limit: integer, wait_ms: integer, turn_id: string?, attempt_id: string?}
M.WAITER_NAME = "bee.threads.waiter"
M.TOPIC_REGISTER = "bee.threads.wait.register"
M.TOPIC_UNREGISTER = "bee.threads.wait.unregister"
M.TOPIC_REGISTERED = "bee.threads.wait.registered"
M.TOPIC_COMMITTED = "bee.threads.committed"
M.MAX_WAIT_MS = 60000
M.BUDGET_MARGIN_MS = 1000
M.REGISTER_ACK_MS = 250
M.FALLBACK_POLL_MS = 1000
M.MAX_WAITERS_PER_THREAD = 64
M.MAX_WAITERS = 1024
local SCAN_WINDOW = 1024
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
-- Effective wait: the request, the 60 s ceiling, and the transport budget
-- minus a margin. A caller can only shorten its budget.
function M.effective_wait(wait_ms: integer, budget_ms: integer?): integer
    local effective = math.min(wait_ms, M.MAX_WAIT_MS)
    if budget_ms then effective = math.min(effective, math.max(0, budget_ms - M.BUDGET_MARGIN_MS)) end
    return math.floor(effective)
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
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function pending(result: Result): boolean
    return result.ok and not result.replayed and type(result.value) == "table" and (result.value :: {[string]: unknown}).status == "empty"
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
    return result.ok and type(result.value) == "table" and (result.value :: {[string]: unknown}).status == "empty"
end
local function watch_final(result: Result): Result
    if not result.ok then return result end
    local value = result.value :: {[string]: unknown}
    if value.status == "empty" then value.status = "timeout" end
    return result
end
-- watch: a bounded, read-only wait for the thread to move past a cursor. It
-- registers with the same waiter as wait, but every check is a read and no
-- obligation is ever claimed. Used by viewers such as the Timeline, whose
-- reading must leave delivery state and history unchanged.
function M.watch(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    -- caller_node_id is the authenticated caller attestation a forwarded
    -- request carries; the admission already verified it, and the owner
    -- accepts it so a cross-node watch is not rejected for naming its caller.
    local unknown_field = bounds.fields(object, {"thread_id", "after_sequence", "wait_ms", "transport_budget_ms", "caller_node_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    if object.caller_node_id ~= nil and not bounds.id(object.caller_node_id) then
        return failure("INVALID_ARGUMENT", "caller_node_id is not an identifier")
    end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    local after = bounds.cursor(object.after_sequence)
    if not after then return failure("INVALID_ARGUMENT", "after_sequence must be between 0 and " .. tostring(bounds.MAX_THREAD_RECORDS)) end
    local wait_ms = bounds.integer(object.wait_ms)
    if not wait_ms or wait_ms < 0 then return failure("INVALID_ARGUMENT", "wait_ms must be a nonnegative integer") end
    local budget: integer? = nil
    if object.transport_budget_ms ~= nil then
        local number = bounds.integer(object.transport_budget_ms)
        if not number or number < 0 then return failure("INVALID_ARGUMENT", "transport_budget_ms must be a nonnegative integer") end
        budget = number
    end
    local effective = M.effective_wait(wait_ms, budget)
    local first = watch_check(db, actor, thread_id, after)
    if not watch_pending(first) then return watch_final(first) end
    if effective == 0 then return watch_final(first) end
    local deadline_at = now_ms() + effective
    local waiter_id, id_err = uuid.v4()
    if id_err or not waiter_id then return failure("INTERNAL", "allocate waiter identifier") end
    local topic = "bee.threads.wakeup." .. waiter_id
    local wakeups, listen_err = process.listen(topic, {message = true})
    if listen_err or not wakeups then return failure("INTERNAL", "subscribe to wakeups") end
    local waiter_pid: string? = nil
    local registered = false
    local lookup, lookup_err = process.registry.lookup(M.WAITER_NAME)
    if not lookup_err and lookup then
        waiter_pid = tostring(lookup)
        local sent = process.send(waiter_pid, M.TOPIC_REGISTER, {version = 1, waiter_id = waiter_id, topic = topic, thread_id = thread_id, after_sequence = after, deadline_at = deadline_at})
        if sent then
            local ack_deadline = time.after(tostring(M.REGISTER_ACK_MS) .. "ms")
            while not registered do
                local selected = channel.select({wakeups:case_receive(), ack_deadline:case_receive()})
                if not selected.ok or selected.channel == ack_deadline then break end
                local message = selected.value
                if tostring(message:from()) == waiter_pid and message:topic() == topic then
                    local data: unknown = message:payload():data()
                    if type(data) == "table" and data.registered == true then registered = true end
                    if type(data) == "table" and data.registered == false then break end
                end
            end
        end
    end
    local function finish(result: Result): Result
        if registered and waiter_pid then process.send(waiter_pid, M.TOPIC_UNREGISTER, {version = 1, waiter_id = waiter_id}) end
        process.unlisten(wakeups)
        return watch_final(result)
    end
    local second = watch_check(db, actor, thread_id, after)
    if not watch_pending(second) then return finish(second) end
    local outcome: Result? = nil
    while not outcome do
        local remaining = deadline_at - now_ms()
        if remaining <= 0 then
            outcome = watch_check(db, actor, thread_id, after)
        else
            local slice = remaining
            if not registered then slice = math.min(remaining, M.FALLBACK_POLL_MS) end
            local timer = time.after(tostring(slice) .. "ms")
            local selected = channel.select({wakeups:case_receive(), timer:case_receive()})
            local woke = false
            if selected.ok and selected.channel == wakeups then
                local message = selected.value
                woke = waiter_pid ~= nil and tostring(message:from()) == waiter_pid
            end
            if woke or not registered or not selected.ok then
                local again = watch_check(db, actor, thread_id, after)
                if not watch_pending(again) then outcome = again end
            end
        end
    end
    return finish(outcome or failure("INTERNAL", "watch ended without an outcome"))
end
function M.wait(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "consumer_id", "after_sequence", "limit", "wait_ms", "transport_budget_ms", "turn_id", "attempt_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local consumer_id = bounds.id(object.consumer_id)
    if not consumer_id then return failure("INVALID_ARGUMENT", "consumer_id is not an identifier") end
    local after = bounds.cursor(object.after_sequence)
    if not after then return failure("INVALID_ARGUMENT", "after_sequence must be between 0 and " .. tostring(bounds.MAX_THREAD_RECORDS)) end
    local limit = bounds.MAX_PAGE_RECORDS
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > bounds.MAX_PAGE_RECORDS then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(bounds.MAX_PAGE_RECORDS)) end
        limit = number
    end
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
    local wait: Wait = {thread_id = mutation.thread_id, consumer_id = consumer_id, after = after, limit = limit, wait_ms = M.effective_wait(wait_ms, budget), turn_id = turn_id, attempt_id = attempt_id}
    local digest, digest_error = canonical.encode({consumer_id = consumer_id, limit = limit, channel = "wait", turn_id = turn_id, attempt_id = attempt_id})
    if not digest then return failure("INVALID_ARGUMENT", digest_error or "request is not encodable") end
    local first = check(db, actor, mutation, wait, digest, wait.wait_ms == 0)
    if not pending(first) then return first end
    local deadline_at = now_ms() + wait.wait_ms
    local waiter_id, id_err = uuid.v4()
    if id_err or not waiter_id then return failure("INTERNAL", "allocate waiter identifier") end
    local topic = "bee.threads.wakeup." .. waiter_id
    local wakeups, listen_err = process.listen(topic, {message = true})
    if listen_err or not wakeups then return failure("INTERNAL", "subscribe to wakeups") end
    local waiter_pid: string? = nil
    local registered = false
    local lookup, lookup_err = process.registry.lookup(M.WAITER_NAME)
    if not lookup_err and lookup then
        waiter_pid = tostring(lookup)
        local sent = process.send(waiter_pid, M.TOPIC_REGISTER, {version = 1, waiter_id = waiter_id, topic = topic, thread_id = wait.thread_id, after_sequence = wait.after, deadline_at = deadline_at})
        if sent then
            local ack_deadline = time.after(tostring(M.REGISTER_ACK_MS) .. "ms")
            while not registered do
                local selected = channel.select({wakeups:case_receive(), ack_deadline:case_receive()})
                if not selected.ok or selected.channel == ack_deadline then break end
                local message = selected.value
                if tostring(message:from()) == waiter_pid and message:topic() == topic then
                    local data: unknown = message:payload():data()
                    if type(data) == "table" and data.registered == true then registered = true end
                    if type(data) == "table" and data.registered == false then break end
                end
            end
        end
    end
    local outcome: Result? = nil
    local function finish(result: Result): Result
        if registered and waiter_pid then process.send(waiter_pid, M.TOPIC_UNREGISTER, {version = 1, waiter_id = waiter_id}) end
        process.unlisten(wakeups)
        return result
    end
    -- Register, then check again: a commit between the first check and the
    -- registration is caught here, a later one by a wakeup.
    local second = check(db, actor, mutation, wait, digest, false)
    if not pending(second) then return finish(second) end
    while not outcome do
        local remaining = deadline_at - now_ms()
        if remaining <= 0 then
            outcome = check(db, actor, mutation, wait, digest, true)
        else
            local slice = remaining
            if not registered then slice = math.min(remaining, M.FALLBACK_POLL_MS) end
            local timer = time.after(tostring(slice) .. "ms")
            local selected = channel.select({wakeups:case_receive(), timer:case_receive()})
            local woke = false
            if selected.ok and selected.channel == wakeups then
                local message = selected.value
                woke = waiter_pid ~= nil and tostring(message:from()) == waiter_pid
            end
            if woke or not registered or not selected.ok then
                local again = check(db, actor, mutation, wait, digest, false)
                if not pending(again) then outcome = again end
            end
        end
    end
    return finish(outcome or failure("INTERNAL", "wait ended without an outcome"))
end
return M

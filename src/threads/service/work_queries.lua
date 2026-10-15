-- MIT. Work observations, history and feed queries.
local sql = require("sql")
local json = require("json")
local journal = require("journal")
local transaction = require("transaction")
local record = require("record")
local bounds = require("bounds")
local commits = require("commits")
local part_session_store = require("part_session_store")
local part_work_records = require("part_work_records")
local M = {}
type Result = part_session_store.Result
type Row = part_session_store.Row
local failure = part_session_store.failure
local object = part_session_store.object
local has_only = part_session_store.has_only
local text = part_session_store.text
local ref = part_session_store.ref
local integer = part_session_store.integer
local authenticated = part_session_store.authenticated
local target_workspace = part_session_store.target_workspace
local missing_request = part_session_store.missing_request
local decode_json = part_session_store.decode_json
local MAX_REF_BYTES = part_work_records.MAX_REF_BYTES
type Work = journal.Work
local MAX_FEED_PAGE = 64
M.MAX_AWAITED_WORKS = 64

local function work_value(work: Work): (Row?, string?)
    local input, input_error = decode_json(work.input_json)
    if input_error then return nil, input_error end
    local value: Row = {work = work.work_ref, session = work.session_ref, sequence = work.sequence, revision = work.revision,
        phase = work.phase, input = input, input_digest = work.input_digest, output_schema = work.output_schema,
        sender = {kind = work.sender_kind, id = work.sender_id}, operation = work.operation_ref,
        created_at = work.created_at}
    local budget, budget_error = decode_json(work.budget_json)
    if budget_error or not object(budget) then return nil, "work budget is corrupt" end
    if next(object(budget) or {}) ~= nil then value.budgets = {turn = budget} end
    if work.result_json then
        local result, result_error = decode_json(work.result_json)
        if result_error then return nil, result_error end
        value.result = result
    end
    if work.uncertainty_json then
        local uncertainty, uncertainty_error = decode_json(work.uncertainty_json)
        if uncertainty_error then return nil, uncertainty_error end
        value.uncertainty = uncertainty
    end
    return value, nil
end

-- describe_work reads one work as work_describe reports it, with the thread
-- of its session.
local function describe_work(tx: sql.Transaction, work_ref: string, workspace: string): (Row?, string?, Result?)
    local work, query_error = journal.work(tx, work_ref, target_workspace(work_ref, workspace))
    if query_error then return nil, nil, transaction.storage_failure(query_error) end
    if not work then return nil, nil, failure("NOT_FOUND", "work does not exist") end
    local value, value_error = work_value(work)
    if not value then return nil, nil, failure("INTERNAL", value_error or "decode work") end
    local execution, execution_error = journal.work_execution(tx, work_ref)
    if execution_error then return nil, nil, transaction.storage_failure(execution_error) end
    if execution then
        value.cancelling = execution.cancellation_work_ref ~= nil
        if execution.cancellation_work_ref ~= nil and type(execution.cancellation_reason) == "string" then
            value.cancel_reason = execution.cancellation_reason
        end
        if execution.turn_ref ~= nil then
            value.turn = execution.turn_ref
            value.claim = execution.claim_token
            value.owner_epoch = execution.owner_epoch
            value.turn_phase = execution.turn_phase
            if type(execution.checkpoint_json) == "string" then
                local checkpoint, checkpoint_error = decode_json(execution.checkpoint_json)
                if checkpoint_error then return nil, nil, failure("INTERNAL", checkpoint_error) end
                value.checkpoint = checkpoint
            end
        end
    end
    local session, session_error = journal.session(tx, work.session_ref, nil)
    if session_error then return nil, nil, transaction.storage_failure(session_error) end
    if not session then return nil, nil, failure("INTERNAL", "work session does not exist") end
    return value, session.thread_id, nil
end

function M.work_describe(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local workspace = assert(workspace)
    local input = object(request)
    local work_ref = input and has_only(input, {work = true}) and ref(input.work) or nil
    if not work_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local value, _, refused = describe_work(tx, work_ref, workspace)
        if not value then return refused or failure("INTERNAL", "work is unavailable") end
        return transaction.success(value, false)
    end)
end

-- A work has an outcome once it holds a result or uncertainty evidence.
local function has_outcome(value: Row): boolean
    return value.result ~= nil or value.uncertainty ~= nil
end

-- work_await reports the listed works once any of them has an outcome, or
-- when the wait ends with timed_out. Every change to a work commits a record
-- on its session's thread in the same transaction, so the wait wakes on those
-- threads' commits and reads again. It claims and changes nothing, and its
-- end cancels no work.
function M.work_await(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {works = true, wait_ms = true, transport_budget_ms = true}) then return missing_request() end
    local listed = bounds.dense_list(input.works, M.MAX_AWAITED_WORKS, "works")
    if not listed or #listed == 0 then
        return failure("INVALID_ARGUMENT", "works must list 1 to " .. tostring(M.MAX_AWAITED_WORKS) .. " work refs")
    end
    local works: {string} = {}
    local seen: {[string]: boolean} = {}
    for index, raw in ipairs(listed) do
        local work_ref = ref(raw)
        if not work_ref or seen[work_ref] then return failure("INVALID_ARGUMENT", "works must be distinct work refs") end
        seen[work_ref] = true
        works[index] = work_ref
    end
    local wait_ms = bounds.integer(input.wait_ms)
    if not wait_ms or wait_ms < 0 then return failure("INVALID_ARGUMENT", "wait_ms must be a nonnegative integer") end
    local budget: integer? = nil
    if input.transport_budget_ms ~= nil then
        budget = bounds.integer(input.transport_budget_ms)
        if not budget or budget < 0 then return failure("INVALID_ARGUMENT", "transport_budget_ms must be a nonnegative integer") end
    end
    local effective = commits.effective_wait(wait_ms, budget)
    local threads: {string} = {}
    -- read reports every work; the final read of a wait without an outcome
    -- reports timed_out.
    local function read(final: boolean): Result
        return transaction.read(db, function(tx: sql.Transaction): Result
            local values: {Row} = {}
            local reached = false
            local known: {[string]: boolean} = {}
            local found: {string} = {}
            for index, work_ref in ipairs(works) do
                local value, thread_id, refused = describe_work(tx, work_ref, workspace)
                if not value or not thread_id then return refused or failure("INTERNAL", "work is unavailable") end
                values[index] = value
                reached = reached or has_outcome(value)
                if not known[thread_id] then known[thread_id], found[#found + 1] = true, thread_id end
            end
            threads = found
            return transaction.success({works = values, timed_out = final and not reached}, false)
        end)
    end
    local function pending(result: Result): boolean
        if not result.ok then return false end
        local value = assert(object(result.value))
        if value.timed_out == true then return false end
        for _, work in ipairs(bounds.array(value.works, M.MAX_AWAITED_WORKS) or {}) do
            local row = object(work)
            if row and has_outcome(row) then return false end
        end
        return true
    end
    local first = read(effective == 0)
    if not pending(first) then return first end
    return commits.await(threads, effective, pending, read, function(message: string): Result
        return failure("INTERNAL", message)
    end)
end

function M.work_history(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {session = true, cursor = true, limit = true}) then return missing_request() end
    local session_ref = ref(input.session)
    local cursor: integer? = input.cursor == nil and 0 or integer(input.cursor)
    local limit: integer? = input.limit == nil and 64 or integer(input.limit)
    if not session_ref or not cursor or cursor < 0 or not limit or limit < 1 or limit > 64 then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, session_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, query_error = journal.work_history(tx, session_ref, cursor, limit + 1)
        if query_error or not rows then return transaction.storage_failure("read session work history") end
        local items: {Row} = {}
        local more = #rows > limit
        for index = 1, math.min(#rows, limit) do
            local row = rows[index]
            local input_value, decode_error = decode_json(tostring(row.input_json))
            if decode_error then return failure("INTERNAL", decode_error) end
            items[#items + 1] = {work = row.work_ref, sequence = row.sequence, input = input_value, created_at = row.created_at}
        end
        return transaction.success({items = items, next = more and items[#items].sequence or nil}, false)
    end)
end

function M.work_scan(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    assert(caller)
    local input = object(request)
    local limit = input and has_only(input, {limit = true, include_hooks = true}) and (input.limit == nil and MAX_FEED_PAGE or integer(input.limit)) or nil
    if not limit or not input or (input.include_hooks ~= nil and type(input.include_hooks) ~= "boolean") or limit < 1 or limit > MAX_FEED_PAGE then return failure("INVALID_ARGUMENT", "work scan limit is outside its bound") end
    local include_hooks = input.include_hooks == true
    return transaction.read(db, function(tx: sql.Transaction): Result
        local rows, query_error = journal.scan_work(tx, include_hooks, workspace, limit)
        if query_error or not rows then return transaction.storage_failure("scan session work") end
        local items: {Row} = {}
        for _, row_value in ipairs(rows) do
            local row = row_value
            local work, work_error = journal.decode_work(row)
            if not work then return failure("INTERNAL", work_error or "decode scanned work") end
            local route_value, route_error = decode_json(tostring(row.route_json or ""))
            if route_error or type(route_value) ~= "table" then return failure("INTERNAL", "session route is corrupt") end
            local item: Row = {work = work.work_ref, session = work.session_ref, state = work.phase,
                sender = {kind = work.sender_kind, id = work.sender_id}, input_digest = work.input_digest,
                output_schema = work.output_schema, route = route_value}
            item.cancel_requested = row.cancellation_work_ref ~= nil
            if type(row.cancellation_reason) == "string" then item.cancel_reason = row.cancellation_reason end
            if work.uncertainty_json then
                local uncertainty, uncertainty_error = decode_json(work.uncertainty_json)
                if uncertainty_error then return failure("INTERNAL", uncertainty_error) end
                item.uncertainty = uncertainty
            end
            if work.phase ~= "queued" then
                local turn_ref, claim_token, owner_epoch = text(row.turn_ref, MAX_REF_BYTES), text(row.claim_token, 128), integer(row.owner_epoch)
                local checkpoint: unknown = nil
                if row.checkpoint_json ~= nil then
                    if type(row.checkpoint_json) ~= "string" then return failure("INTERNAL", "turn checkpoint is corrupt") end
                    checkpoint, route_error = decode_json(row.checkpoint_json)
                    if route_error then return failure("INTERNAL", route_error) end
                end
                if not turn_ref or not claim_token or not owner_epoch then return failure("INTERNAL", "active turn identity is corrupt") end
                item.turn = turn_ref
                item.claim = claim_token
                item.owner_epoch = owner_epoch
                item.checkpoint = checkpoint
            end
            items[#items + 1] = item
        end
        if include_hooks then
            local windows, window_error = journal.interactive_obligations(tx, workspace)
            if window_error or not windows then return transaction.storage_failure("scan interactive session obligations") end
            return transaction.success({items = items, interactive_active = #windows > 0}, false)
        end
        return transaction.success({items = items}, false)
    end)
end

local function extension_payload(encoded: string): (Row?, string?, string?)
    local stored, decode_error = record.decode_json(encoded)
    if not stored or stored.kind ~= "observation" then return nil, nil, decode_error or "journal record is not an observation" end
    local body = stored.body
    if body.type ~= "extension" or body.data.type ~= "extension" then return nil, nil, "journal event schema is invalid" end
    local extension = body.data
    if extension.event_name ~= "bee.sessions.event" or extension.event_revision ~= "1" then return nil, nil, "journal event revision is unsupported" end
    local payload, payload_error = json.decode(extension.payload_json)
    if payload_error or type(payload) ~= "table" then return nil, nil, "journal event payload is corrupt" end
    return payload, body.observed_at, nil
end

function M.feed_read(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {session = true, after_sequence = true, limit = true}) then return missing_request() end
    local session_ref = ref(input.session)
    local cursor = input.after_sequence == nil and 0 or integer(input.after_sequence)
    local limit: integer? = MAX_FEED_PAGE
    if input.limit ~= nil then limit = integer(input.limit) end
    if not session_ref or cursor == nil or not limit or limit < 1 or limit > MAX_FEED_PAGE then
        return failure("INVALID_ARGUMENT", "session, after_sequence or feed limit is invalid")
    end
    local page_limit = limit
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, query_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, records_error = journal.feed(tx, session.thread_id, session_ref, cursor, page_limit + 1)
        if records_error or not rows then return transaction.storage_failure("read session feed") end
        local events: {Row} = {}
        local next_cursor = cursor
        local has_more = #rows > page_limit
        local event_count: integer = #rows
        if event_count > page_limit then event_count = page_limit end
        for index = 1, event_count do
            local row = rows[index]
            local event_id, sequence = text(row.record_id, 160), integer(row.sequence)
            local encoded, committed_at = type(row.record_json) == "string" and row.record_json or nil, text(row.committed_at, 64)
            if not event_id or not sequence or not encoded or not committed_at then return failure("INTERNAL", "session feed row is corrupt") end
            local payload, observed_at, payload_error = extension_payload(encoded)
            if not payload then return failure("INTERNAL", payload_error or "decode session event") end
            if payload.kind == "work.queued" then
                local work, work_error = journal.work(tx, tostring(payload.subject), session.workspace_id)
                if not work then return transaction.storage_failure(work_error or "session event work is missing") end
                local input_value, input_error = decode_json(work.input_json)
                if input_error then return failure("INTERNAL", input_error) end
                local detail = object(payload.data)
                if not detail then return failure("INTERNAL", "session event data is corrupt") end
                detail.input = input_value
            end
            events[#events + 1] = {owner = "threads", id = event_id, schema = "bee.sessions.event@1", sequence = sequence,
                recorded_at = committed_at, observed_at = observed_at,
                session_ref = payload.session_ref, kind = payload.kind, subject = payload.subject, revision = payload.revision,
                operation = payload.operation, data = payload.data}
            next_cursor = sequence
        end
        return transaction.success({session = session_ref, events = events, cursor = next_cursor, has_more = has_more}, false)
    end)
end


M.failure = failure
M.object = object
M.has_only = has_only
M.text = text
M.ref = ref
M.integer = integer
M.authenticated = authenticated
M.target_workspace = target_workspace
M.missing_request = missing_request
M.decode_json = decode_json
M.MAX_REF_BYTES = MAX_REF_BYTES
M.MAX_FEED_PAGE = MAX_FEED_PAGE
M.work_value = work_value
M.describe_work = describe_work
M.has_outcome = has_outcome
M.extension_payload = extension_payload
return M

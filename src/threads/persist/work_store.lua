-- MIT. Canonical session and work state shares the thread journal, its
-- transaction boundary and owner epoch; queue rows are indexes, not inboxes.
local sql = require("sql")
local access = require("access")
local journal = require("journal")
local transaction = require("transaction")
local observation = require("observation")
local bounds = require("bounds")
local budget_values = require("budget_values")
local inbox = require("inbox")
local ctx = require("ctx")
local usage = require("usage")
local M = {}
local part_work_queries = require("part_work_queries")
type Result = part_work_queries.Result
type Row = part_work_queries.Row
local failure = part_work_queries.failure
local object = part_work_queries.object
local has_only = part_work_queries.has_only
local text = part_work_queries.text
local ref = part_work_queries.ref
local authenticated = part_work_queries.authenticated
local target_workspace = part_work_queries.target_workspace
local missing_request = part_work_queries.missing_request
local decode_json = part_work_queries.decode_json
local MAX_REF_BYTES = part_work_queries.MAX_REF_BYTES
type Work = part_work_queries.Work
local MAX_FEED_PAGE = part_work_queries.MAX_FEED_PAGE
M.MAX_AWAITED_WORKS = part_work_queries.MAX_AWAITED_WORKS
M.work_describe = part_work_queries.work_describe
M.work_await = part_work_queries.work_await
M.work_history = part_work_queries.work_history
M.work_scan = part_work_queries.work_scan
M.feed_read = part_work_queries.feed_read
local part_session_store = require("part_session_store")
type Session = part_session_store.Session
local key = part_session_store.key
local now_ms = part_session_store.now_ms
local encode = part_session_store.encode
local digest = part_session_store.digest
local allocate_id = part_session_store.allocate_id
local qualified = part_session_store.qualified
local mutation_workspace = part_session_store.mutation_workspace
local append_event = part_session_store.append_event
local node_and_operation = part_session_store.node_and_operation
local operation_context = part_session_store.operation_context
local finish_operation = part_session_store.finish_operation
local current_epoch = part_session_store.current_epoch
M.session_create = part_session_store.session_create
M.session_attach = part_session_store.session_attach
local consumption = part_session_store.consumption
M.session_describe = part_session_store.session_describe
M.node_summary = part_session_store.node_summary
M.session_scan = part_session_store.session_scan
M.session_transition = part_session_store.session_transition
local part_work_records = require("part_work_records")
local budget_json = part_work_records.budget_json
type Turn = journal.Turn
local function result_value(value: unknown, expected_schema: string?): (string?, Row?, string?)
    local result = object(value)
    if not result then return nil, nil, "result must be an object" end
    local state = text(result.state, 32)
    if state == "succeeded" then
        if not has_only(result, {state = true, schema = true, value = true, artifacts = true, usage = true}) then return nil, nil, "successful result has unknown fields" end
        local schema = text(result.schema, MAX_REF_BYTES)
        if not schema or result.value == nil then return nil, nil, "successful result requires schema and value" end
        if expected_schema and schema ~= expected_schema then return nil, nil, "result schema does not match the admitted output schema" end
    elseif state == "failed" or state == "cancelled" or state == "rejected" then
        if not has_only(result, {state = true, error = true, artifacts = true}) then return nil, nil, "unsuccessful result has unknown fields" end
        local fault = object(result.error)
        if not fault or not text(fault.code, 128) or not text(fault.message, 4096) then return nil, nil, "unsuccessful result requires a typed fault" end
    elseif state == "budget_exceeded" then
        if not has_only(result, {state = true, error = true, artifacts = true, evidence = true}) then
            return nil, nil, "budget result has unknown fields"
        end
        local fault, evidence = object(result.error), object(result.evidence)
        local evidence_artifacts = evidence and bounds.array(evidence.artifacts, MAX_FEED_PAGE) or nil
        if not fault or fault.code ~= "BUDGET_EXCEEDED" or not text(fault.message, 4096)
            or not evidence or not text(evidence.summary, 4096) or not evidence_artifacts then
            return nil, nil, "budget result requires typed stop evidence"
        end
        for _, artifact in ipairs(evidence_artifacts) do
            if not text(artifact, 4096) then return nil, nil, "budget stop evidence has an invalid artifact" end
        end
    else
        return nil, nil, "result state must be settled"
    end
    local encoded, encode_error = encode(result)
    if not encoded then return nil, nil, encode_error end
    return encoded, result, nil
end

function M.work_send(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {session = true, operation_key = true, input = true, output_schema = true, budget = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    local output_schema = input.output_schema == nil and "bee:Text@1" or text(input.output_schema, MAX_REF_BYTES)
    local input_json, input_error = encode(input.input)
    local selected_budget_json, budget_error = budget_json(input.budget)
    if not session_ref or not operation_key or not output_schema or input.input == nil or not input_json or not selected_budget_json then
        return failure("INVALID_ARGUMENT", input_error or budget_error or "session, key, input, output schema or budget is invalid")
    end
    local input_digest = digest(input_json)
    if not input_digest then return failure("INTERNAL", "measure immutable work input") end
    local peer_context = bounds.object(ctx.get("bee.hive.caller"))
    local origin = peer_context and bounds.object(peer_context.origin)
    if origin and (not access.forwarded(caller) or not bounds.id(origin.thread_id) or not bounds.id(origin.session)
        or tostring(origin.session):match("^bs:([^:]+):") ~= peer_context.node) then
        return failure("DENIED", "session origin requires an authenticated Hive peer")
    end
    local arguments = {session = session_ref, input = input_json, output_schema = output_schema, budget = selected_budget_json}
    workspace = mutation_workspace(session_ref, workspace, "send")
    if not workspace then return failure("DENIED", "sending requires a host workspace grant") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace, operation_key, "work_send", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local session, session_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        if session.state == "closing" or session.state == "closed" then return failure("CONFLICT", "session is not accepting work") end
        local route = object(decode_json(session.route_json))
        local budgets, budget_error = budget_values.budgets(route and route.budgets)
        if budget_error then return failure("INTERNAL", budget_error) end
        local ceiling = budgets and budgets.session
        if ceiling then
            local used, used_error = consumption(tx, session_ref)
            if not used then return failure("INTERNAL", used_error or "session consumption unavailable") end
            for _, field in ipairs({"wall_time_ms", "provider_steps", "tool_calls", "tokens"}) do
                local limit, amount = ceiling[field], bounds.count(used[field])
                if limit and amount and amount >= limit then return failure("BUDGET_EXCEEDED", "session " .. field .. " intake ceiling reached") end
            end
        end
        local node, op_ref, reference_error = node_and_operation(nil, workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local id, id_error = allocate_id()
        if not id then return failure("INTERNAL", id_error or "allocate work reference") end
        local work_ref = qualified("bw", node, workspace, id)
        local now = transaction.now()
        local sender_kind = origin and "session" or caller:match("^bs:") and "session" or "principal"
        local sender_id = origin and tostring(origin.session) or caller
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "work.queued", work_ref, 1,
            {session = session_ref, input_digest = input_digest, output_schema = output_schema,
                sender = {kind = sender_kind, id = sender_id}})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work event") end
        if origin and peer_context then
            local refused = inbox.session_request(tx, session, caller, work_ref, input.input, origin)
            if refused then return refused end
        end
        local work_error = journal.insert_work(tx, work_ref, session_ref, workspace, sequence, input_json, input_digest, output_schema, sender_kind, sender_id, op_ref, now, selected_budget_json)
        if work_error then return failure("INTERNAL", work_error) end
        local receipt = {work = work_ref, session = session_ref, operation = op_ref, committed_at = now, sequence = sequence,
            kind = "request", state = "queued", output_schema = output_schema, sender = {kind = sender_kind, id = sender_id}}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "work_send", request_digest, work_ref, receipt, now)
    end)
end

function M.work_cancel(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {work = true, reason = true, operation_key = true}) then return missing_request() end
    local work_ref, operation_key = ref(input.work), key(input.operation_key)
    local reason = input.reason == nil and nil or text(input.reason, 16384)
    if not work_ref or not operation_key or (input.reason ~= nil and not reason) then
        return failure("INVALID_ARGUMENT", "work, reason or operation_key is invalid")
    end
    local arguments: Row = {work = work_ref}
    if reason then arguments.reason = reason end
    workspace = mutation_workspace(work_ref, workspace, "cancel")
    if not workspace then return failure("DENIED", "cancellation requires a host workspace grant") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace,
            operation_key, "work_cancel", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local work, work_error = journal.work(tx, work_ref, target_workspace(work_ref, workspace))
        if work_error then return transaction.storage_failure(work_error) end
        if not work then return failure("NOT_FOUND", "work does not exist") end
        local session, session_error = journal.session(tx, work.session_ref, target_workspace(work.session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "work session does not exist") end
        local node, op_ref, reference_error = node_and_operation(nil, session.workspace_id)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        if work.phase == "queued" then
            local summary = reason or "work cancelled before executor activation"
            local cancelled = {state = "cancelled", error = {code = "CANCELLED", message = summary},
                artifacts = {"work was cancelled before executor activation"}}
            local result_json, checked_result, checked_error = result_value(cancelled, work.output_schema)
            if not result_json or not checked_result then return failure("INVALID_ARGUMENT", checked_error or "cancellation result is invalid") end
            local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "work.cancelled",
                work.work_ref, work.revision + 1, {before_activation = true, reason = summary})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append cancellation event") end
            local inbox_error = inbox.session_reply(tx, session, work.work_ref, checked_result)
            if inbox_error then return inbox_error end
            local update_error = journal.cancel_queued_work(tx, result_json, work.work_ref)
            if update_error then return failure("CONFLICT", update_error) end
        elseif work.phase == "reserved" or work.phase == "accepted" then
            local insert_error = journal.insert_cancellation(tx, work.work_ref, op_ref, reason, now)
            if insert_error then return failure("INTERNAL", insert_error) end
            local _, sequence, event_error = append_event(tx, session, caller, op_ref, "work.cancel_requested",
                work.work_ref, work.revision + 1, {reason = reason or ""})
            if not sequence then return failure("INTERNAL", event_error or "append cancellation request") end
            local update_error = journal.mark_cancelling(tx, work.work_ref)
            if update_error then return failure("CONFLICT", update_error) end
        end
        local receipt = {operation = op_ref, subject = work.work_ref, state = "requested", effect = "cancel"}
        return finish_operation(tx, caller, session.workspace_id, operation_key, op_ref, "work_cancel",
            request_digest, work.work_ref, receipt, now)
    end)
end

function M.operation_lookup(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    local operation_key = input and has_only(input, {operation_key = true}) and key(input.operation_key) or nil
    if not operation_key then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local row, query_error = journal.operation_by_key(tx, workspace, caller, operation_key)
        if query_error then return transaction.storage_failure(query_error) end
        if not row then return transaction.success({found = false, operation_key = operation_key}, false) end
        if type(row.receipt_json) ~= "string" then return failure("INTERNAL", "operation receipt is corrupt") end
        local receipt, decode_error = decode_json(row.receipt_json)
        if decode_error then return failure("INTERNAL", decode_error) end
        return transaction.success({found = true, operation_key = operation_key, operation = row.operation,
            operation_ref = row.operation_ref, target = row.target_ref, request_digest = row.request_digest,
            committed_at = row.committed_at, receipt = receipt}, false)
    end)
end

function M.operation_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    local operation_ref = input and has_only(input, {operation = true}) and ref(input.operation) or nil
    if not operation_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local row, query_error = journal.operation_by_ref(tx, workspace, caller, operation_ref)
        if query_error then return transaction.storage_failure(query_error) end
        if not row then return failure("NOT_FOUND", "operation does not exist") end
        if type(row.receipt_json) ~= "string" then return failure("INTERNAL", "operation receipt is corrupt") end
        local receipt, decode_error = decode_json(row.receipt_json)
        if decode_error then return failure("INTERNAL", decode_error) end
        return transaction.success({found = true, operation_key = row.operation_key, operation = row.operation,
            operation_ref = row.operation_ref, target = row.target_ref, request_digest = row.request_digest,
            committed_at = row.committed_at, receipt = receipt}, false)
    end)
end

function M.turn_reserve(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {session = true, operation_key = true, work = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    local selected_work = input.work == nil and nil or ref(input.work)
    if not session_ref or not operation_key or (input.work ~= nil and not selected_work) then return missing_request() end
    local arguments = {session = session_ref, work = selected_work}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local session, session_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local scope_workspace = session.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller, scope_workspace, operation_key, "turn_reserve", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        if session.state ~= "active" and session.state ~= "closing" then
            local receipt = {session = session_ref, turn = nil, state = session.state, operation = op_ref, committed_at = now}
            return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest, session_ref, receipt, now)
        end
        local active_row, active_error = journal.active_turn(tx, session_ref)
        if active_error then return transaction.storage_failure(active_error) end
        if active_row then
            local active, decode_error = journal.decode_turn(active_row)
            if not active then return failure("INTERNAL", decode_error or "active turn is corrupt") end
            if active.owner_epoch ~= epoch then return failure("UNKNOWN_OUTCOME", "an earlier owner epoch has an unsettled turn") end
            local receipt = {session = session_ref, turn = nil, state = "busy", operation = op_ref, committed_at = now}
            return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest, session_ref, receipt, now)
        end
        -- A named work is reserved itself, ahead of older queued work: a
        -- prompt the agent submitted is the turn it runs.
        local work_row_data, work_error
        if selected_work then work_row_data, work_error = journal.queued_work_ref(tx, session_ref, selected_work)
        else work_row_data, work_error = journal.queued_work(tx, session_ref) end
        if work_error then return transaction.storage_failure(work_error) end
        if selected_work and not work_row_data then return failure("CONFLICT", "the named work is not queued in this session") end
        if not work_row_data then
            local receipt = {session = session_ref, turn = nil, state = "idle", operation = op_ref, committed_at = now}
            return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest, session_ref, receipt, now)
        end
        local work, decode_error = journal.decode_work(work_row_data)
        if not work then return failure("INTERNAL", decode_error or "queued work is corrupt") end
        local turn_id, turn_id_error = allocate_id()
        local claim, claim_error = allocate_id()
        if not turn_id or not claim then return failure("INTERNAL", turn_id_error or claim_error or "allocate turn claim") end
        local turn_ref = qualified("bturn", node, scope_workspace, turn_id)
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "turn.reserved", work.work_ref,
            work.revision + 1, {turn = turn_ref, input_digest = work.input_digest, owner_epoch = epoch})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn reservation") end
        local insert_error = journal.insert_turn(tx, turn_ref, session_ref, work.work_ref, claim, epoch, work.input_digest, record_id, now)
        if insert_error then return failure("CONFLICT", insert_error) end
        local work_update_error = journal.reserve_work(tx, work.work_ref)
        if work_update_error then return failure("CONFLICT", work_update_error) end
        local receipt = {session = session_ref, work = work.work_ref, turn = turn_ref, claim = claim,
            input_digest = work.input_digest, owner_epoch = epoch, state = "reserved", operation = op_ref,
            committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest, work.work_ref, receipt, now)
    end)
end

function M.turn_recover(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, operation_key = true}) then return missing_request() end
    local turn_ref, operation_key = ref(input.turn), key(input.operation_key)
    if not turn_ref or not operation_key then return missing_request() end
    local arguments = {turn = turn_ref}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn, turn_error = journal.turn(tx, turn_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn then return failure("NOT_FOUND", "turn does not exist") end
        if turn.phase == "settled" then return failure("CONFLICT", "settled turn cannot be recovered") end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local session, session_error = journal.session(tx, turn.session_ref, target_workspace(turn.session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller, scope_workspace,
            operation_key, "turn_recover", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local claim_token = turn.claim_token
        if turn.owner_epoch ~= epoch then
            local allocated, allocation_error = allocate_id()
            if not allocated then return failure("INTERNAL", allocation_error or "allocate recovered turn claim") end
            claim_token = allocated
            local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
            if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
            local now = transaction.now()
            local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "turn.recovered", turn.work_ref,
                turn.owner_epoch + 1, {turn = turn.turn_ref, previous_epoch = turn.owner_epoch, owner_epoch = epoch})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn recovery") end
            local update_error = journal.recover_turn(tx, claim_token, epoch, turn.turn_ref)
            if update_error then return failure("CONFLICT", update_error) end
            local receipt = {session = turn.session_ref, work = turn.work_ref, turn = turn.turn_ref, claim = claim_token,
                input_digest = turn.input_digest, owner_epoch = epoch, state = turn.phase, operation = op_ref,
                committed_at = now, sequence = sequence}
            return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_recover",
                request_digest, turn.work_ref, receipt, now)
        end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local receipt = {session = turn.session_ref, work = turn.work_ref, turn = turn.turn_ref, claim = claim_token,
            input_digest = turn.input_digest, owner_epoch = epoch, state = turn.phase, operation = op_ref, committed_at = now}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_recover",
            request_digest, turn.work_ref, receipt, now)
    end)
end

local function claimed_turn(tx: sql.Transaction, turn_ref: string, claim_token: string, workspace: string?): (Turn?, Work?, Session?, Result?)
    local turn, turn_error = journal.turn(tx, turn_ref)
    if turn_error then return nil, nil, nil, transaction.storage_failure(turn_error) end
    if not turn then return nil, nil, nil, failure("NOT_FOUND", "turn does not exist") end
    if turn.claim_token ~= claim_token then return nil, nil, nil, failure("DENIED", "turn claim is invalid") end
    local epoch, epoch_error = current_epoch(tx)
    if not epoch then return nil, nil, nil, failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
    if turn.owner_epoch ~= epoch then return nil, nil, nil, failure("STALE", "turn belongs to an earlier owner epoch") end
    local session, session_error = journal.session(tx, turn.session_ref, target_workspace(turn.session_ref, workspace))
    if session_error then return nil, nil, nil, transaction.storage_failure(session_error) end
    if not session then return nil, nil, nil, failure("NOT_FOUND", "turn session does not exist") end
    local work, work_error = journal.work(tx, turn.work_ref, target_workspace(turn.work_ref, session.workspace_id))
    if work_error then return nil, nil, nil, transaction.storage_failure(work_error) end
    if not work then return nil, nil, nil, failure("NOT_FOUND", "turn work does not exist") end
    return turn, work, session, nil
end

function M.work_uncertain(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, claim = true, evidence = true, operation_key = true}) then return missing_request() end
    local turn_ref, claim_token, operation_key = ref(input.turn), text(input.claim, 128), key(input.operation_key)
    local evidence = object(input.evidence)
    if not evidence or not text(evidence.summary, 16384) or type(evidence.artifacts) ~= "table" then
        return failure("INVALID_ARGUMENT", "uncertainty evidence is malformed")
    end
    local evidence_json, evidence_error = encode(evidence)
    if not turn_ref or not claim_token or not operation_key or not evidence_json then
        return failure("INVALID_ARGUMENT", evidence_error or "uncertainty fields are invalid")
    end
    local arguments = {turn = turn_ref, claim = claim_token, evidence = evidence_json}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref, claim_token, workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "uncertain turn context is incomplete") end
        if turn.phase ~= "accepted" or work.phase ~= "accepted" then return failure("CONFLICT", "only an accepted turn can be marked uncertain") end
        local request_digest, replay, context_error = operation_context(tx, caller, session.workspace_id,
            operation_key, "work_uncertain", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local now = transaction.now()
        local node, op_ref, reference_error = node_and_operation(nil, session.workspace_id)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local _, sequence, event_error = append_event(tx, session, caller, op_ref, "work.uncertain", work.work_ref,
            work.revision + 1, evidence)
        if not sequence then return failure("INTERNAL", event_error or "append uncertainty event") end
        local update_error = journal.mark_uncertain(tx, evidence_json, work.work_ref)
        if update_error then return failure("CONFLICT", update_error) end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref,
            state = "uncertain", evidence = evidence, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, session.workspace_id, operation_key, op_ref, "work_uncertain",
            request_digest, work.work_ref, receipt, now)
    end)
end

function M.turn_pull(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, claim = true}) then return missing_request() end
    local turn_ref, claim_token = ref(input.turn), text(input.claim, 128)
    if not turn_ref or not claim_token then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref, claim_token, workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "fenced turn envelope is incomplete") end
        local input_value, input_error = decode_json(work.input_json)
        if input_error then return failure("INTERNAL", input_error) end
        local route_value, route_error = decode_json(session.route_json)
        if route_error then return failure("INTERNAL", route_error) end
        local context_value, context_error = decode_json(session.context_json)
        if context_error or type(context_value) ~= "table" then return failure("INTERNAL", "session context is corrupt") end
        local budget_value, budget_error = decode_json(work.budget_json)
        if budget_error or not object(budget_value) then return failure("INTERNAL", "work budget is corrupt") end
        local checkpoint: unknown = nil
        if turn.checkpoint_json then
            checkpoint, route_error = decode_json(turn.checkpoint_json)
            if route_error then return failure("INTERNAL", route_error) end
        end
        local pulled: Row = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref,
            claim = turn.claim_token, owner_epoch = turn.owner_epoch, input = input_value, input_digest = turn.input_digest,
            output_schema = work.output_schema, sender = {kind = work.sender_kind, id = work.sender_id},
            route = route_value, checkpoint = checkpoint, context = context_value, phase = turn.phase}
        if next(object(budget_value) or {}) ~= nil then pulled.budget = budget_value end
        local used, usage_error = consumption(tx, session.session_ref)
        if not used then return failure("INTERNAL", usage_error or "session consumption is unavailable") end
        pulled.session_consumption = used
        return transaction.success(pulled, false)
    end)
end

function M.turn_accept(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, claim = true, input_digest = true, checkpoint = true, operation_key = true}) then return missing_request() end
    local turn_ref, claim_token, input_digest = ref(input.turn), text(input.claim, 128), text(input.input_digest, 128)
    local operation_key = key(input.operation_key)
    local checkpoint_json, checkpoint_error = encode(input.checkpoint)
    if not turn_ref or not claim_token or not input_digest or not operation_key or not checkpoint_json then
        return failure("INVALID_ARGUMENT", checkpoint_error or "turn acceptance fields are invalid")
    end
    local arguments = {turn = turn_ref, claim = claim_token, input_digest = input_digest, checkpoint = checkpoint_json}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn_identity, turn_error = journal.turn(tx, turn_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn_identity then return failure("NOT_FOUND", "turn does not exist") end
        local session_identity, session_error = journal.session(tx, turn_identity.session_ref, target_workspace(turn_identity.session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session_identity then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session_identity.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller, scope_workspace, operation_key, "turn_accept", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref, claim_token, scope_workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "turn acceptance context is incomplete") end
        if turn.phase ~= "reserved" or work.phase ~= "reserved" then return failure("CONFLICT", "only a reserved turn can be accepted") end
        if input_digest ~= turn.input_digest or input_digest ~= work.input_digest then return failure("CONFLICT", "accepted input digest does not match the frozen work") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "turn.accepted", work.work_ref,
            work.revision + 1, {turn = turn.turn_ref, input_digest = input_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn acceptance") end
        local progress_at = now_ms()
        local update_turn_error = journal.accept_turn(tx, checkpoint_json, record_id, progress_at, turn.turn_ref, turn.owner_epoch)
        if update_turn_error then return failure("CONFLICT", update_turn_error) end
        local start_error = journal.start_budget(tx, now_ms(), session.session_ref)
        if start_error then return failure("INTERNAL", start_error) end
        local inbox_error = inbox.session_accepted(tx, session.thread_id, work.work_ref)
        if inbox_error then return inbox_error end
        local update_work_error = journal.accept_work(tx, work.work_ref)
        if update_work_error then return failure("CONFLICT", update_work_error) end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref, state = "accepted",
            operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "turn_accept", request_digest, work.work_ref, receipt, now)
    end)
end

function M.turn_observation(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, claim = true, operation_key = true, observation = true, checkpoint = true}) then
        return missing_request()
    end
    local turn_ref, claim_token, operation_key = ref(input.turn), text(input.claim, 128), key(input.operation_key)
    local decoded_observation, observation_error = observation.decode(input.observation)
    local observation_json = decoded_observation and encode(decoded_observation) or nil
    if not turn_ref or not claim_token or not operation_key or not decoded_observation or not observation_json then
        return failure("INVALID_ARGUMENT", observation_error or "turn observation fields are invalid")
    end
    local checkpoint_json: string? = nil
    if input.checkpoint ~= nil then
        if not object(input.checkpoint) then return failure("INVALID_ARGUMENT", "turn checkpoint must be an object") end
        local checkpoint_error: string?
        checkpoint_json, checkpoint_error = encode(input.checkpoint)
        if not checkpoint_json or #checkpoint_json > 65536 then return failure("INVALID_ARGUMENT", checkpoint_error or "turn checkpoint exceeds 65536 bytes") end
    end
    local arguments = {turn = turn_ref, claim = claim_token, observation = observation_json, checkpoint = checkpoint_json}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn_identity, turn_error = journal.turn(tx, turn_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn_identity then return failure("NOT_FOUND", "turn does not exist") end
        local session_identity, session_error = journal.session(tx, turn_identity.session_ref, target_workspace(turn_identity.session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session_identity then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session_identity.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller, scope_workspace,
            operation_key, "turn_observation", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref, claim_token, scope_workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "turn observation context is incomplete") end
        if turn.phase ~= "accepted" or work.phase ~= "accepted" then return failure("CONFLICT", "only an accepted turn may append observations") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local before, usage_error = usage.turn(tx, session.thread_id, turn, nil)
        if not before then return failure("INTERNAL", usage_error or "read turn usage") end
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "turn.observation",
            work.work_ref, work.revision, {turn = turn.turn_ref, observation = decoded_observation})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn observation") end
        if checkpoint_json then
            local checkpoint_error = journal.checkpoint_turn(tx, checkpoint_json, turn.turn_ref, turn.owner_epoch)
            if checkpoint_error then return transaction.storage_failure(checkpoint_error) end
        end
        local progress_error = journal.turn_progress(tx, now_ms(), turn.turn_ref, turn.owner_epoch)
        if progress_error then return failure("CONFLICT", progress_error) end
        local data = decoded_observation.data
        local observed, usage_error = usage.turn(tx, session.thread_id, turn, nil)
        if not observed then return failure("INTERNAL", usage_error or "read turn usage") end
        local steps = data.type == "turn.signal" and data.phase == "started" and 1 or 0
        local tools = (observed.tool_calls or 0) - (before.tool_calls or 0)
        local tokens = math.floor(math.min(bounds.MAX_SAFE_INTEGER, (observed.input_tokens or 0) + (observed.output_tokens or 0)))
            - math.floor(math.min(bounds.MAX_SAFE_INTEGER, (before.input_tokens or 0) + (before.output_tokens or 0)))
        local session_progress_error = journal.session_progress(tx, now, steps, tools, tokens, session.session_ref)
        if session_progress_error then return failure("INTERNAL", session_progress_error) end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref,
            event_key = decoded_observation.event_key, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref,
            "turn_observation", request_digest, work.work_ref, receipt, now)
    end)
end

function M.work_settle(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {turn = true, claim = true, result = true, operation_key = true, context = true}) then return missing_request() end
    local turn_ref, claim_token, operation_key = ref(input.turn), text(input.claim, 128), key(input.operation_key)
    local result_json, decoded_result, result_error = result_value(input.result, nil)
    if not turn_ref or not claim_token or not operation_key or not result_json or not decoded_result then
        return failure("INVALID_ARGUMENT", result_error or "settlement fields are invalid")
    end
    local context_json: string? = nil
    if input.context ~= nil then
        local encoded, context_error = encode(input.context)
        if not encoded or type(input.context) ~= "table" then return failure("INVALID_ARGUMENT", context_error or "context must be an object") end
        context_json = encoded
    end
    local arguments: Row = {turn = turn_ref, claim = claim_token, result = result_json}
    if context_json then arguments.context = context_json end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn_identity, turn_error = journal.turn(tx, turn_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn_identity then return failure("NOT_FOUND", "turn does not exist") end
        local session_identity, session_error = journal.session(tx, turn_identity.session_ref, target_workspace(turn_identity.session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session_identity then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session_identity.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller, scope_workspace, operation_key, "work_settle", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref, claim_token, scope_workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "work settlement context is incomplete") end
        if turn.phase ~= "accepted" or work.phase ~= "accepted" then return failure("CONFLICT", "only accepted work can be settled") end
        local checked_json, checked_result, checked_error = result_value(decoded_result, work.output_schema)
        if not checked_json or not checked_result then return failure("INVALID_ARGUMENT", checked_error or "work result is invalid") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local result_digest = digest(checked_json)
        if not result_digest then return failure("INTERNAL", "measure work result") end
        local now = transaction.now()
        local next_revision = work.revision + 1
        local per_turn, usage_error = usage.turn(tx, session.thread_id, turn, checked_result.usage)
        if not per_turn then return failure("INVALID_ARGUMENT", usage_error or "turn usage is invalid") end
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "work.settled", work.work_ref,
            next_revision, {turn = turn.turn_ref, state = checked_result.state, result_digest = result_digest, usage = per_turn})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work settlement") end
        local turn_error = journal.settle_turn(tx, record_id, turn.turn_ref, turn.owner_epoch)
        if turn_error then return failure("CONFLICT", turn_error) end
        local work_error = journal.settle_work(tx, next_revision, checked_json, work.work_ref)
        if work_error then return failure("CONFLICT", work_error) end
        if context_json then
            local context_error = journal.save_context(tx, context_json, now, session.session_ref)
            if context_error then return failure("INTERNAL", context_error) end
        end
        local inbox_error = inbox.session_reply(tx, session, work.work_ref, checked_result)
        if inbox_error then return inbox_error end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref, phase = "settled",
            result = checked_result, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "work_settle", request_digest, work.work_ref, receipt, now)
    end)
end

return M

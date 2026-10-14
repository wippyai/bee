-- MIT. SQL repository for the Sessions journal in the Threads owner transaction.
local sql = require("sql")
local bounds = require("bounds")
local M = {}
type Row = {[string]: unknown}
type Session = {session_ref: string, thread_id: string, workspace_id: string, owner_actor: string, title: string,
    state: string, revision: integer, created_at: string, updated_at: string, route_json: string, context_json: string}
type Work = {work_ref: string, session_ref: string, workspace_id: string, sequence: integer, revision: integer,
    phase: string, input_json: string, input_digest: string, output_schema: string, sender_kind: string, sender_id: string,
    result_json: string?, uncertainty_json: string?, operation_ref: string, created_at: string, budget_json: string}
type Turn = {turn_ref: string, session_ref: string, work_ref: string, claim_token: string, owner_epoch: integer,
    input_digest: string, phase: string, checkpoint_json: string?, reserve_record_id: string,
    accept_record_id: string?, settle_record_id: string?, created_at: string}
local MAX_REF_BYTES = 256

local function text(value: unknown, maximum: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > maximum or value:find("%c") then return nil end
    return value
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > bounds.MAX_SAFE_INTEGER then return nil end
    return math.floor(value)
end

local function query_one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): (Row?, string?)
    local rows, query_error = tx:query(statement, params)
    if query_error or not rows then return nil, "read " .. label end
    if #rows > 1 then return nil, label .. " rows are corrupt" end
    if #rows == 0 then return nil, nil end
    return rows[1], nil
end

local function execute(tx: sql.Transaction, statement: string, params: {unknown}, label: string): string?
    local _, execute_error = tx:execute(statement, params)
    if execute_error then return label end
    return nil
end

local function session_row(row: Row): (Session?, string?)
    local session_ref, thread_id = text(row.session_ref, MAX_REF_BYTES), text(row.thread_id, 160)
    local workspace, owner_actor = text(row.workspace_id, 32), text(row.owner_actor, 160)
    local title, state = text(row.title, 512), text(row.state, 32)
    local revision = integer(row.revision)
    local created_at, updated_at = text(row.created_at, 64), text(row.updated_at, 64)
    local route_json = type(row.route_json) == "string" and row.route_json or nil
    local context_json = type(row.context_json) == "string" and row.context_json or nil
    if not session_ref or not thread_id or not workspace or not owner_actor or not title or not state or not revision or not created_at or not updated_at or not route_json or not context_json then
        return nil, "session row is corrupt"
    end
    return {session_ref = session_ref, thread_id = thread_id, workspace_id = workspace, owner_actor = owner_actor,
        title = title, state = state, revision = revision, created_at = created_at, updated_at = updated_at,
        route_json = route_json, context_json = context_json}, nil
end

function M.decode_work(row: Row): (Work?, string?)
    local work_ref, session_ref = text(row.work_ref, MAX_REF_BYTES), text(row.session_ref, MAX_REF_BYTES)
    local workspace, input_json = text(row.workspace_id, 32), type(row.input_json) == "string" and row.input_json or nil
    local input_digest, output_schema = text(row.input_digest, 128), text(row.output_schema, MAX_REF_BYTES)
    local budget_json_value = type(row.budget_json) == "string" and row.budget_json or nil
    local sender_kind, sender_id = text(row.sender_kind, 16), text(row.sender_id, MAX_REF_BYTES)
    local phase = text(row.phase, 32)
    local sequence, revision = integer(row.sequence), integer(row.revision)
    local operation_ref, created_at = text(row.operation_ref, MAX_REF_BYTES), text(row.created_at, 64)
    local result_json: string? = nil
    if row.result_json ~= nil then
        if type(row.result_json) ~= "string" then return nil, "work result is corrupt" end
        result_json = row.result_json
    end
    local uncertainty_json: string? = nil
    if row.uncertainty_json ~= nil then
        if type(row.uncertainty_json) ~= "string" then return nil, "work uncertainty is corrupt" end
        uncertainty_json = row.uncertainty_json
    end
    if not work_ref or not session_ref or not workspace or not input_json or not input_digest or not output_schema
        or (sender_kind ~= "session" and sender_kind ~= "principal") or not sender_id
        or not phase or not sequence or not revision or not operation_ref or not created_at or not budget_json_value then return nil, "work row is corrupt" end
    return {work_ref = work_ref, session_ref = session_ref, workspace_id = workspace, sequence = sequence,
        revision = revision, phase = phase, input_json = input_json, input_digest = input_digest,
        output_schema = output_schema, sender_kind = sender_kind, sender_id = sender_id, result_json = result_json,
        uncertainty_json = uncertainty_json, operation_ref = operation_ref, created_at = created_at,
        budget_json = budget_json_value}, nil
end

function M.decode_turn(row: Row): (Turn?, string?)
    local turn_ref, session_ref, work_ref = text(row.turn_ref, MAX_REF_BYTES), text(row.session_ref, MAX_REF_BYTES), text(row.work_ref, MAX_REF_BYTES)
    local claim_token, input_digest, phase = text(row.claim_token, 128), text(row.input_digest, 128), text(row.phase, 32)
    local owner_epoch = integer(row.owner_epoch)
    local reserve_record_id, created_at = text(row.reserve_record_id, 160), text(row.created_at, 64)
    local checkpoint_json: string? = nil
    if row.checkpoint_json ~= nil then
        if type(row.checkpoint_json) ~= "string" then return nil, "turn checkpoint is corrupt" end
        checkpoint_json = row.checkpoint_json
    end
    local accept_record_id: string? = nil
    if row.accept_record_id ~= nil then
        if type(row.accept_record_id) ~= "string" then return nil, "turn acceptance is corrupt" end
        accept_record_id = row.accept_record_id
    end
    local settle_record_id: string? = nil
    if row.settle_record_id ~= nil then
        if type(row.settle_record_id) ~= "string" then return nil, "turn settlement is corrupt" end
        settle_record_id = row.settle_record_id
    end
    if not turn_ref or not session_ref or not work_ref or not claim_token or not input_digest or not phase or not owner_epoch or owner_epoch < 1
        or not reserve_record_id or not created_at then return nil, "turn row is corrupt" end
    return {turn_ref = turn_ref, session_ref = session_ref, work_ref = work_ref, claim_token = claim_token,
        owner_epoch = owner_epoch, input_digest = input_digest, phase = phase, checkpoint_json = checkpoint_json,
        reserve_record_id = reserve_record_id, accept_record_id = accept_record_id,
        settle_record_id = settle_record_id, created_at = created_at}, nil
end

function M.session(tx: sql.Transaction, session_ref: string, workspace: string?): (Session?, string?)
    local row, query_error = query_one(tx, "SELECT session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json, context_json " ..
        "FROM bee_sessions WHERE session_ref = ? AND (? IS NULL OR workspace_id = ?)", {session_ref, workspace or sql.NULL, workspace or sql.NULL}, "session")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return session_row(row)
end

function M.work(tx: sql.Transaction, work_ref: string, workspace: string?): (Work?, string?)
    local row, query_error = query_one(tx, "SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
        "output_schema, sender_kind, sender_id, result_json, uncertainty_json, operation_ref, created_at, budget_json FROM bee_session_work WHERE work_ref = ? AND (? IS NULL OR workspace_id = ?)", {work_ref, workspace or sql.NULL, workspace or sql.NULL}, "work")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return M.decode_work(row)
end

function M.turn(tx: sql.Transaction, turn_ref: string): (Turn?, string?)
    local row, query_error = query_one(tx, "SELECT turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, " ..
        "reserve_record_id, accept_record_id, settle_record_id, created_at FROM bee_session_turns WHERE turn_ref = ?", {turn_ref}, "turn")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return M.decode_turn(row)
end

function M.operation_receipt(tx: sql.Transaction, workspace: string, actor: string,
    operation_key: string): (Row?, string?)
    return query_one(tx, "SELECT operation, request_digest, receipt_json FROM bee_session_operations " ..
        "WHERE workspace_id = ? AND owner_actor = ? AND operation_key = ?", {workspace, actor, operation_key}, "operation receipt")
end

function M.insert_operation(tx: sql.Transaction, workspace: string, actor: string, operation_key: string,
    operation_ref: string, operation: string, request_digest: string, target_ref: string?, receipt_json: string,
    committed_at: string): string?
    return execute(tx, "INSERT INTO bee_session_operations (workspace_id, owner_actor, operation_key, operation_ref, operation, " ..
        "request_digest, target_ref, receipt_json, committed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", {workspace, actor, operation_key, operation_ref, operation, request_digest, target_ref or sql.NULL, receipt_json, committed_at}, "store operation receipt")
end

function M.head(tx: sql.Transaction, thread_id: string): (Row?, string?)
    return query_one(tx, "SELECT head_sequence FROM bee_thread_heads WHERE thread_id = ?", {thread_id}, "journal head")
end

function M.interactive_thread(tx: sql.Transaction, existing_thread: string): (Row?, string?)
    return query_one(tx, "SELECT owner_actor, workspace_id FROM bee_thread_heads WHERE thread_id = ?", {existing_thread}, "interactive thread")
end

function M.insert_session(tx: sql.Transaction, session_ref: string, thread_id: string, workspace: string,
    caller: string, title: string, now: string, stored_route_json: string): string?
    return execute(tx, "INSERT INTO bee_sessions (session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json) " ..
        "VALUES (?, ?, ?, ?, ?, 'active', 1, ?, ?, ?)", {session_ref, thread_id, workspace, caller, title, now, now, stored_route_json}, "create session")
end

function M.attach_session(tx: sql.Transaction, route_json: string, now: string, session_ref: string): string?
    return execute(tx, "UPDATE bee_sessions SET route_json = ?, state = 'active', revision = revision + 1, updated_at = ? WHERE session_ref = ?", {route_json, now, session_ref}, "attach session window")
end

function M.consumption(tx: sql.Transaction, session: string): (Row?, string?)
    return query_one(tx, "SELECT budget_started_at_ms, provider_steps, tool_calls, tokens FROM bee_sessions WHERE session_ref = ?", {session}, "session budget consumption")
end

function M.work_counts(tx: sql.Transaction, session_ref: string): ({Row}?, string?)
    return tx:query("SELECT phase, COUNT(*) AS count, " ..
        "SUM(CASE WHEN uncertainty_json IS NOT NULL THEN 1 ELSE 0 END) AS uncertain " ..
        "FROM bee_session_work WHERE session_ref = ? GROUP BY phase", {session_ref})
end

function M.unreconciled_turns(tx: sql.Transaction, session_ref: string, epoch: integer): (Row?, string?)
    return query_one(tx, "SELECT COUNT(*) AS count FROM bee_session_turns " ..
        "WHERE session_ref = ? AND phase IN ('reserved','accepted') AND owner_epoch <> ?", {session_ref, epoch}, "unreconciled session turns")
end

function M.last_result(tx: sql.Transaction, session_ref: string): ({Row}?, string?)
    return tx:query("SELECT work_ref, result_json, created_at FROM bee_session_work WHERE session_ref = ? AND phase = 'settled' ORDER BY sequence DESC LIMIT 1", {session_ref})
end

function M.first_work(tx: sql.Transaction, session_ref: string): (Row?, string?)
    return query_one(tx, "SELECT input_json FROM bee_session_work WHERE session_ref = ? ORDER BY sequence LIMIT 1", {session_ref}, "first session work")
end

function M.session_activity(tx: sql.Transaction, session_ref: string): (Row?, string?)
    return query_one(tx, "SELECT turn_ref, claim_token, work_ref, owner_epoch, phase, last_progress_at_ms " ..
        "FROM bee_session_turns WHERE session_ref = ? AND phase IN ('reserved','accepted')", {session_ref}, "active session turn")
end

-- attempt_turn_ended reports whether a native attempt took a message and
-- ended its turn: its terminal's input is proven to accept typed messages.
function M.attempt_turn_ended(tx: sql.Transaction, session_ref: string, attempt_id: string): (boolean?, string?)
    local rows, err = tx:query("SELECT 1 AS found FROM bee_session_turns t JOIN bee_session_work w ON w.work_ref = t.work_ref " ..
        "WHERE t.session_ref = ? AND t.phase = 'settled' AND json_extract(t.checkpoint_json, '$.attempt_id') = ? " ..
        "AND COALESCE(json_extract(w.result_json, '$.error.code'), '') <> 'UNDELIVERED' LIMIT 1", {session_ref, attempt_id})
    if err or not rows then return nil, "read attempt turns" end
    return #rows > 0, nil
end

function M.executing_sessions(tx: sql.Transaction, epoch: integer): ({Row}?, string?)
    return tx:query("SELECT COUNT(DISTINCT s.session_ref) AS count FROM bee_sessions s " ..
        "JOIN bee_session_work w ON w.session_ref = s.session_ref " ..
        "JOIN bee_session_turns t ON t.work_ref = w.work_ref AND t.session_ref = s.session_ref " ..
        "WHERE s.state <> 'closed' AND w.phase = 'accepted' AND t.phase = 'accepted' AND t.owner_epoch = ? " ..
        "AND NOT EXISTS (SELECT 1 FROM bee_session_turns old WHERE old.session_ref = s.session_ref " ..
        "AND old.phase IN ('reserved','accepted') AND old.owner_epoch <> ?)", {epoch, epoch})
end

function M.workspaces(tx: sql.Transaction): ({Row}?, string?)
    return tx:query("SELECT DISTINCT workspace_id FROM bee_sessions", {})
end

function M.scan_sessions(tx: sql.Transaction, workspaces: {string}, cursor: string?, limit: integer): ({Row}?, string?)
    local parameters: {unknown} = {}
    local placeholders: {string} = {}
    for _, workspace in ipairs(workspaces) do
        parameters[#parameters + 1] = workspace
        placeholders[#placeholders + 1] = "?"
    end
    parameters[#parameters + 1] = cursor or sql.NULL
    parameters[#parameters + 1] = cursor or sql.NULL
    parameters[#parameters + 1] = limit
    return tx:query("SELECT session_ref, workspace_id FROM bee_sessions WHERE workspace_id IN (" ..
            table.concat(placeholders, ",") .. ") AND (? IS NULL OR session_ref > ?) ORDER BY session_ref LIMIT ?", parameters)
end

function M.unsettled_work(tx: sql.Transaction, session_ref: string): (Row?, string?)
    return query_one(tx, "SELECT COUNT(*) AS count FROM bee_session_work WHERE session_ref = ? AND phase <> 'settled'", {session_ref}, "unsettled work")
end

function M.transition_session(tx: sql.Transaction, target: string, revision: integer, now: string, session_ref: string,
    expected_revision: integer): string?
    return execute(tx, "UPDATE bee_sessions SET state = ?, revision = ?, updated_at = ? WHERE session_ref = ? AND revision = ?", {target, revision, now, session_ref, expected_revision}, "update session lifecycle")
end

function M.insert_work(tx: sql.Transaction, work_ref: string, session_ref: string, workspace: string,
    sequence: integer, input_json: string, input_digest: string, output_schema: string, sender_kind: string,
    caller: string, op_ref: string, now: string, selected_budget_json: string): string?
    return execute(tx, "INSERT INTO bee_session_work (work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
        "output_schema, sender_kind, sender_id, result_json, operation_ref, created_at, budget_json) VALUES (?, ?, ?, ?, 1, 'queued', ?, ?, ?, ?, ?, NULL, ?, ?, ?)", {work_ref, session_ref, workspace, sequence, input_json, input_digest, output_schema, sender_kind, caller, op_ref, now, selected_budget_json}, "enqueue work")
end

function M.work_execution(tx: sql.Transaction, work_ref: string): (Row?, string?)
    return query_one(tx, "SELECT t.turn_ref, t.claim_token, t.owner_epoch, t.phase AS turn_phase, " ..
        "t.checkpoint_json, c.work_ref AS cancellation_work_ref, c.reason AS cancellation_reason " ..
        "FROM bee_session_work w LEFT JOIN bee_session_turns t ON t.work_ref = w.work_ref AND t.phase IN ('reserved','accepted') " ..
        "LEFT JOIN bee_session_work_cancellations c ON c.work_ref = w.work_ref WHERE w.work_ref = ?", {work_ref}, "work execution state")
end

function M.work_history(tx: sql.Transaction, session_ref: string, cursor: integer, limit: integer): ({Row}?, string?)
    return tx:query("SELECT work_ref, sequence, input_json, created_at FROM bee_session_work WHERE session_ref = ? AND sequence > ? ORDER BY sequence LIMIT ?", {session_ref, cursor, limit})
end

function M.scan_work(tx: sql.Transaction, include_hooks: boolean, workspace: string?, limit: integer): ({Row}?, string?)
    return tx:query("SELECT w.work_ref, w.session_ref, w.workspace_id, w.sequence, w.revision, w.phase, w.input_json, w.input_digest, " ..
        "w.output_schema, w.sender_kind, w.sender_id, w.result_json, w.uncertainty_json, w.operation_ref, w.created_at, w.budget_json, " ..
        "t.turn_ref, t.claim_token, t.owner_epoch, t.checkpoint_json, s.route_json, s.context_json, " ..
        "c.work_ref AS cancellation_work_ref, c.reason AS cancellation_reason " ..
        "FROM bee_session_work w JOIN bee_sessions s ON s.session_ref = w.session_ref " ..
        "LEFT JOIN bee_session_turns t ON t.work_ref = w.work_ref AND t.phase IN ('reserved','accepted') " ..
        "LEFT JOIN bee_session_work_cancellations c ON c.work_ref = w.work_ref " ..
        "WHERE w.phase IN ('queued','reserved','accepted') AND (? = 1 OR COALESCE(json_extract(s.route_json, '$.delivery'), 'pull') = 'pull') AND (? IS NULL OR s.workspace_id = ?) AND s.state IN ('active','closing') AND " ..
        "(c.work_ref IS NOT NULL OR w.phase IN ('reserved','accepted') OR (w.phase = 'queued' AND w.sequence = " ..
        "(SELECT MIN(q.sequence) FROM bee_session_work q WHERE q.session_ref = w.session_ref AND q.phase = 'queued'))) " ..
        "ORDER BY w.sequence LIMIT ?", {include_hooks and 1 or 0, workspace or sql.NULL, workspace or sql.NULL, limit})
end

function M.interactive_obligations(tx: sql.Transaction, workspace: string?): ({Row}?, string?)
    return tx:query("SELECT session_ref FROM bee_sessions WHERE state <> 'closed' " ..
        "AND json_extract(route_json, '$.delivery') = 'hook' AND (? IS NULL OR workspace_id = ?) LIMIT 1", {workspace or sql.NULL, workspace or sql.NULL})
end

function M.cancel_queued_work(tx: sql.Transaction, result_json: string, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET phase = 'settled', revision = revision + 1, result_json = ? " ..
        "WHERE work_ref = ? AND phase = 'queued'", {result_json, work_ref}, "settle queued cancellation")
end

function M.insert_cancellation(tx: sql.Transaction, work_ref: string, op_ref: string, reason: string?,
    now: string): string?
    return execute(tx, "INSERT INTO bee_session_work_cancellations " ..
        "(work_ref, operation_ref, reason, requested_at) VALUES (?, ?, ?, ?) ON CONFLICT(work_ref) DO NOTHING", {work_ref, op_ref, reason or sql.NULL, now}, "record work cancellation")
end

function M.mark_cancelling(tx: sql.Transaction, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET revision = revision + 1 " ..
        "WHERE work_ref = ? AND phase IN ('reserved','accepted')", {work_ref}, "mark work cancelling")
end

function M.operation_by_key(tx: sql.Transaction, workspace: string, caller: string,
    operation_key: string): (Row?, string?)
    return query_one(tx, "SELECT operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at " ..
        "FROM bee_session_operations WHERE workspace_id = ? AND owner_actor = ? AND operation_key = ?", {workspace, caller, operation_key}, "operation lookup")
end

function M.operation_by_ref(tx: sql.Transaction, workspace: string, caller: string,
    operation_ref: string): (Row?, string?)
    return query_one(tx, "SELECT operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at " ..
        "FROM bee_session_operations WHERE workspace_id = ? AND owner_actor = ? AND operation_ref = ?", {workspace, caller, operation_ref}, "operation")
end

function M.feed(tx: sql.Transaction, thread_id: string, session_ref: string, cursor: integer, limit: integer): ({Row}?, string?)
    return tx:query("SELECT record_id, sequence, record_json, committed_at FROM bee_thread_records " ..
        "WHERE thread_id = ? AND event_scope = 'sessions' AND json_extract(json_extract(record_json, '$.body.data.payload_json'), '$.session_ref') = ? AND sequence > ? ORDER BY sequence LIMIT ?", {thread_id, session_ref, cursor, limit})
end

local TURN_COLUMNS = "turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, " ..
    "reserve_record_id, accept_record_id, settle_record_id, created_at"

function M.active_turn(tx: sql.Transaction, session_ref: string): (Row?, string?)
    return query_one(tx, "SELECT " .. TURN_COLUMNS .. " FROM bee_session_turns " ..
        "WHERE session_ref = ? AND phase IN ('reserved','accepted')", {session_ref}, "active turn")
end

function M.queued_work_ref(tx: sql.Transaction, session_ref: string, work_ref: string): (Row?, string?)
    return query_one(tx, "SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
        "output_schema, sender_kind, sender_id, result_json, operation_ref, created_at, budget_json FROM bee_session_work " ..
        "WHERE session_ref = ? AND work_ref = ? AND phase = 'queued'", {session_ref, work_ref}, "queued work")
end

function M.queued_work(tx: sql.Transaction, session_ref: string): (Row?, string?)
    return query_one(tx, "SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
        "output_schema, sender_kind, sender_id, result_json, operation_ref, created_at, budget_json FROM bee_session_work " ..
        "WHERE session_ref = ? AND phase = 'queued' ORDER BY sequence LIMIT 1", {session_ref}, "queued work")
end

function M.insert_turn(tx: sql.Transaction, turn_ref: string, session_ref: string, work_ref: string, claim: string,
    epoch: integer, input_digest: string, record_id: string, now: string): string?
    return execute(tx, "INSERT INTO bee_session_turns (turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, " ..
        "checkpoint_json, reserve_record_id, accept_record_id, settle_record_id, created_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, 'reserved', NULL, ?, NULL, NULL, ?)", {turn_ref, session_ref, work_ref, claim, epoch, input_digest, record_id, now}, "reserve turn")
end

function M.reserve_work(tx: sql.Transaction, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET phase = 'reserved', revision = revision + 1 " ..
        "WHERE work_ref = ? AND phase = 'queued'", {work_ref}, "mark work reserved")
end

function M.recover_turn(tx: sql.Transaction, claim_token: string, epoch: integer, turn_ref: string): string?
    return execute(tx, "UPDATE bee_session_turns SET claim_token = ?, owner_epoch = ? WHERE turn_ref = ? AND phase IN ('reserved','accepted')", {claim_token, epoch, turn_ref}, "recover turn claim")
end

function M.mark_uncertain(tx: sql.Transaction, evidence_json: string, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET uncertainty_json = ?, revision = revision + 1 " ..
        "WHERE work_ref = ? AND phase = 'accepted'", {evidence_json, work_ref}, "mark work uncertain")
end

function M.accept_turn(tx: sql.Transaction, checkpoint_json: string, record_id: string, progress_at: integer,
    turn_ref: string, owner_epoch: integer): string?
    return execute(tx, "UPDATE bee_session_turns SET phase = 'accepted', checkpoint_json = ?, accept_record_id = ?, last_progress_at_ms = ? " ..
        "WHERE turn_ref = ? AND owner_epoch = ? AND phase = 'reserved'", {checkpoint_json, record_id, progress_at, turn_ref, owner_epoch}, "accept turn")
end

function M.start_budget(tx: sql.Transaction, now_ms: integer, session_ref: string): string?
    return execute(tx, "UPDATE bee_sessions SET budget_started_at_ms = CASE WHEN budget_started_at_ms = 0 THEN ? ELSE budget_started_at_ms END WHERE session_ref = ?", {now_ms, session_ref}, "start session budget clock")
end

function M.accept_work(tx: sql.Transaction, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET phase = 'accepted', revision = revision + 1 " ..
        "WHERE work_ref = ? AND phase = 'reserved'", {work_ref}, "mark work accepted")
end

function M.checkpoint_turn(tx: sql.Transaction, checkpoint_json: string, turn_ref: string,
    owner_epoch: integer): string?
    return execute(tx, "UPDATE bee_session_turns SET checkpoint_json = ? WHERE turn_ref = ? AND owner_epoch = ?", {checkpoint_json, turn_ref, owner_epoch}, "checkpoint turn observation")
end

function M.turn_progress(tx: sql.Transaction, now_ms: integer, turn_ref: string, owner_epoch: integer): string?
    return execute(tx, "UPDATE bee_session_turns SET last_progress_at_ms = ? " ..
        "WHERE turn_ref = ? AND owner_epoch = ? AND phase = 'accepted'", {now_ms, turn_ref, owner_epoch}, "record live turn progress")
end

function M.session_progress(tx: sql.Transaction, now: string, steps: integer, tools: integer, tokens: integer,
    session_ref: string): string?
    return execute(tx, "UPDATE bee_sessions SET updated_at = ?, provider_steps = MIN(9007199254740991, provider_steps + ?), tool_calls = MIN(9007199254740991, tool_calls + ?), tokens = MIN(9007199254740991, tokens + ?) WHERE session_ref = ?", {now, steps, tools, tokens, session_ref}, "record session consumption")
end

function M.settle_turn(tx: sql.Transaction, record_id: string, turn_ref: string, owner_epoch: integer): string?
    return execute(tx, "UPDATE bee_session_turns SET phase = 'settled', settle_record_id = ? " ..
        "WHERE turn_ref = ? AND owner_epoch = ? AND phase = 'accepted'", {record_id, turn_ref, owner_epoch}, "settle turn")
end

function M.settle_work(tx: sql.Transaction, next_revision: integer, checked_json: string, work_ref: string): string?
    return execute(tx, "UPDATE bee_session_work SET phase = 'settled', revision = ?, result_json = ? " ..
        "WHERE work_ref = ? AND phase = 'accepted'", {next_revision, checked_json, work_ref}, "settle work")
end

function M.save_context(tx: sql.Transaction, context_json: string, now: string, session_ref: string): string?
    return execute(tx, "UPDATE bee_sessions SET context_json = ?, updated_at = ? WHERE session_ref = ?", {context_json, now, session_ref}, "save session context")
end

return M

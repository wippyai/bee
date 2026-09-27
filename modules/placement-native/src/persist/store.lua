-- MIT. The receipts store: attempts and their append-only evidence. Every
-- transition is one transaction that checks the state machine, appends
-- evidence and bumps the attempt, so a projection never runs ahead of its
-- proof.
local sql = require("sql")
local json = require("json")
local time = require("time")
local persist = require("persist")
local migrations = require("migrations")
local resources = require("resources")
local types = require("types")
local transitions = require("transitions")
local request_protocol = require("request_protocol")
local configuration = require("configuration")
local bounds = require("bounds")
local M = {}
M.LEDGER = {table = "bee_placement_schema_migrations", label = "placement"}
M.MAX_EVIDENCE_PAGE = 64
M.MAX_DETAIL_BYTES = 2048
type Row = {[string]: unknown}
type Update = {
    expected_execution: types.ExecutionState?,
    execution: types.ExecutionState?,
    cleanup: types.CleanupState?,
    fields: {[string]: unknown}?,
    evidence: {kind: string, detail: string},
}
type Result = {ok: boolean, code: string?, message: string?, attempt: types.Attempt?}
type Measured = {capability: types.Capability, exit_observation: types.ExitObservation}
type Placement = {kind: string, spec_json: string?, identity_json: string?}
function M.now(): string
    return time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
end
function M.open(): (sql.DB?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, resource_error end
    return persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
end
local integer = bounds.integer
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function project(row: Row): (types.Attempt?, string?)
    local attempt_id, action_id, owner_id = bounds.id(row.attempt_id), bounds.id(row.action_id), bounds.id(row.owner_id)
    local request_digest = bounds.text(row.request_digest, 64)
    local execution_text = bounds.member(row.execution_state, {"intended", "starting", "running", "stopping", "exited", "uncertain"})
    local cleanup_text = bounds.member(row.cleanup_state, {"pending", "complete", "uncertain"})
    local capability_text = bounds.member(row.capability, {"direct_process", "process_group", "contained_tree"})
    local required_text = bounds.member(row.required_cleanup, {"direct_process", "process_group", "contained_tree"})
    local observation_text = bounds.member(row.exit_observation, {"independent", "eof_gated"})
    local execution: types.ExecutionState? = nil
    if execution_text == "intended" then execution = "intended"
    elseif execution_text == "starting" then execution = "starting"
    elseif execution_text == "running" then execution = "running"
    elseif execution_text == "stopping" then execution = "stopping"
    elseif execution_text == "exited" then execution = "exited"
    elseif execution_text == "uncertain" then execution = "uncertain" end
    local cleanup: types.CleanupState? = nil
    if cleanup_text == "pending" then cleanup = "pending"
    elseif cleanup_text == "complete" then cleanup = "complete"
    elseif cleanup_text == "uncertain" then cleanup = "uncertain" end
    local capability: types.Capability? = nil
    if capability_text == "direct_process" then capability = "direct_process"
    elseif capability_text == "process_group" then capability = "process_group"
    elseif capability_text == "contained_tree" then capability = "contained_tree" end
    local required: types.Capability? = nil
    if required_text == "direct_process" then required = "direct_process"
    elseif required_text == "process_group" then required = "process_group"
    elseif required_text == "contained_tree" then required = "contained_tree" end
    local observation: types.ExitObservation? = nil
    if observation_text == "independent" then observation = "independent"
    elseif observation_text == "eof_gated" then observation = "eof_gated" end
    local code, signal = integer(row.exit_code), integer(row.exit_signal)
    local owner_incarnation, attachment_generation, evidence_count =
        integer(row.owner_incarnation), integer(row.attachment_generation), integer(row.evidence_count)
    local request_digest_valid = request_digest ~= nil and #request_digest == 64 and request_digest:match("^[0-9a-f]+$") ~= nil
    local created_at, updated_at = bounds.timestamp(row.created_at), bounds.timestamp(row.updated_at)
    local exit_source: string? = nil
    if row.exit_source ~= nil then exit_source = bounds.id(row.exit_source) end
    local session_ref: string? = nil
    if row.session_ref ~= nil then session_ref = bounds.id(row.session_ref) end
    local runner: string? = nil
    if row.runner_pid ~= nil then runner = bounds.id(row.runner_pid) end
    local home_key: string? = nil
    if row.home_key ~= nil then home_key = bounds.id(row.home_key) end
    if not attempt_id or not action_id or not owner_id or not request_digest_valid or not execution or not cleanup or not capability or not required
        or not observation or not created_at or not updated_at or (row.exit_source ~= nil and not exit_source)
        or (row.session_ref ~= nil and not session_ref) or (row.runner_pid ~= nil and not runner) or (row.home_key ~= nil and not home_key) then
        return nil, "attempt identity, state or timestamp fields are corrupt"
    end
    if not owner_incarnation or owner_incarnation < 1 or not attachment_generation or attachment_generation < 0
        or not evidence_count or evidence_count < 0 then return nil, "attempt integer fields are corrupt" end
    if (row.exit_code ~= nil and code == nil) or (row.exit_signal ~= nil and signal == nil) then return nil, "attempt exit status is corrupt" end
    local exit: types.Exit? = nil
    if code ~= nil or signal ~= nil then exit = {code = code, signal = signal} end
    local home: string? = nil
    if home_key then home = "home:" .. home_key end
    return {
        attempt_id = attempt_id, action_id = action_id, owner_id = owner_id,
        owner_incarnation = owner_incarnation, request_digest = text(row.request_digest) or "",
        execution_state = execution, cleanup_state = cleanup, capability = capability, required_cleanup = required,
        exit_observation = observation, exit_source = exit_source,
        attachment_generation = attachment_generation, exit = exit, session_ref = text(row.session_ref),
        home_ref = home, runner = runner, evidence_count = evidence_count,
        created_at = created_at, updated_at = updated_at,
    }, nil
end
-- The full row, for the runner and the service; never returned to callers.
function M.row(db: sql.DB, attempt_id: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_placement_attempts WHERE attempt_id = ?", {attempt_id})
    if err or not rows then return nil, "read attempt" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
function M.attempt(db: sql.DB, attempt_id: string): (types.Attempt?, string?)
    local row, err = M.row(db, attempt_id)
    if err then return nil, err end
    if not row then return nil, nil end
    return project(row)
end
function M.by_key(db: sql.DB, owner_id: string, key: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_placement_attempts WHERE owner_id = ? AND idempotency_key = ?", {owner_id, key})
    if err or not rows then return nil, "read attempt by key" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
-- Immutable composition-base identity is stored outside the provider-writable
-- retained HOME. A later attempt reuses this digest instead of adopting current
-- host configuration or whatever bytes happen to occupy the retained path.
function M.session_file_digest(db: sql.DB, owner_id: string, session_ref: string, path: string): (string?, string?)
    local rows, err = db:query([[SELECT digest FROM bee_placement_session_files
        WHERE owner_id = ? AND session_ref = ? AND path = ?]], {owner_id, session_ref, path})
    if err or not rows then return nil, "read retained configuration binding" end
    if #rows == 0 then return nil, nil end
    local digest = text((rows[1] :: Row).digest)
    if not digest or not digest:match("^[0-9a-f]+$") or #digest ~= 64 then
        return nil, "retained configuration binding is invalid"
    end
    return digest, nil
end
function M.bind_session_file(db: sql.DB, owner_id: string, session_ref: string, path: string, digest: string): string?
    local existing, read_error = M.session_file_digest(db, owner_id, session_ref, path)
    if read_error then return read_error end
    if existing then
        if existing ~= digest then return "retained configuration binding changed" end
        return nil
    end
    local result, insert_error = db:execute([[INSERT INTO bee_placement_session_files
        (owner_id, session_ref, path, digest, created_at) VALUES (?, ?, ?, ?, ?)]],
        {owner_id, session_ref, path, digest, M.now()})
    if not result or insert_error then
        local raced, race_error = M.session_file_digest(db, owner_id, session_ref, path)
        if race_error then return race_error end
        if raced == digest then return nil end
        return raced and "retained configuration binding changed" or "write retained configuration binding"
    end
    return nil
end
function M.request(row: Row): (types.LaunchRequest?, string?)
    local encoded = text(row.request_json)
    if not encoded then return nil, "attempt request is missing" end
    local decoded, err = json.decode(encoded)
    if err or type(decoded) ~= "table" then return nil, "attempt request is unreadable" end
    -- Persisted JSON is another typed boundary. Decode the original admitted
    -- request separately from the private delivery callers cannot supply.
    local stored = decoded :: {[string]: unknown}
    local admitted: {[string]: unknown} = {}
    for key, value in pairs(stored) do
        if key ~= "delivery" then admitted[key] = value end
    end
    local request, request_error = request_protocol.decode(admitted)
    if not request then return nil, "attempt request: " .. tostring(request_error) end
    -- request_digest measures caller input for retry identity. The stored
    -- request contains owner-resolved resource grants, so it is not that input.
    if request.attempt_id ~= row.attempt_id or request.owner_id ~= row.owner_id or request.action_id ~= row.action_id then
        return nil, "attempt request identity differs from its row"
    end
    local delivery, delivery_error = configuration.decode_stored_delivery(stored.delivery)
    if not delivery then return nil, "attempt delivery: " .. tostring(delivery_error) end
    local retained: types.LaunchRequest = request
    retained.delivery = delivery
    return retained, nil
end
-- Derive the retained session's HOME choice from the original admitted
-- request. Callers receive only the choice, never either physical path.
function M.private_home(row: Row): (boolean?, string?)
    if text(row.session_ref) == nil then return nil, nil end
    local request, request_error = M.request(row)
    if not request then return nil, request_error end
    if request.session_ref ~= text(row.session_ref) or not request.launch.home_ref then
        return nil, "retained placement request has another session home"
    end
    local selected = request.environment_refs.HOME
    if selected == nil then return true, nil end
    if selected == "bee.env:machine_home" then return false, nil end
    return nil, "retained placement request has an unsupported HOME selection"
end
local function rollback(tx: sql.Transaction)
    tx:rollback()
end
local function append(tx: sql.Transaction, attempt_id: string, count: integer, kind: string, detail: string, at: string): (integer?, string?)
    local sequence = count + 1
    local bounded = detail
    if #bounded > M.MAX_DETAIL_BYTES then bounded = bounded:sub(1, M.MAX_DETAIL_BYTES) end
    local _, err = tx:execute("INSERT INTO bee_placement_evidence (attempt_id, sequence, at, kind, detail) VALUES (?, ?, ?, ?, ?)",
        {attempt_id, sequence, at, kind, bounded})
    if err then return nil, "append evidence" end
    return sequence, nil
end
-- Records intent: the attempt exists before anything external does.
function M.intend(db: sql.DB, request: types.LaunchRequest, digest: string, encoded: string, measured: Measured, grants_json: string?, placement: Placement?): Result
    local tx, begin_err = db:begin()
    if not tx then return {ok = false, code = "STORAGE", message = "begin intent"} end
    local at = M.now()
    -- The session home is writable state, so it has one unfinished holder.
    -- This predicate is part of the insert transaction: an observation before
    -- the insert cannot admit a second holder. A completed cleanup is the
    -- only release; exit alone deliberately leaves the holder in place.
    local inserted, insert_err = tx:execute([[INSERT INTO bee_placement_attempts (attempt_id, owner_id, owner_incarnation, action_id, idempotency_key,
        request_digest, request_json, grants_json, placement_kind, placement_spec_json, placement_identity_json,
        execution_state, cleanup_state, capability, required_cleanup, exit_observation, session_ref, evidence_count, created_at, updated_at)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'intended', 'pending', ?, ?, ?, ?, 1, ?, ?
        WHERE ? IS NULL OR NOT EXISTS (
            SELECT 1 FROM bee_placement_attempts
            WHERE session_ref = ? AND owner_id = ?
              AND NOT (execution_state = 'exited' AND cleanup_state = 'complete')
        )]],
        {request.attempt_id, request.owner_id, request.owner_incarnation, request.action_id, request.idempotency_key, digest, encoded, grants_json,
            placement and placement.kind or nil, placement and placement.spec_json or nil, placement and placement.identity_json or nil,
            measured.capability, request.required_cleanup, measured.exit_observation, request.session_ref, at, at,
            request.session_ref, request.session_ref, request.owner_id})
    if insert_err then
        rollback(tx)
        -- The service normally finds a replay before reaching this point.
        -- This fallback preserves that result if two identical prepares race
        -- between its read and this guarded insert.
        local existing, existing_error = M.by_key(db, request.owner_id, request.idempotency_key)
        if existing_error then return {ok = false, code = "STORAGE", message = existing_error} end
        if existing and existing.request_digest == digest then return {ok = true, attempt = project(existing)} end
        -- The attempt id is the durable identity and its uniqueness is not
        -- scoped to an owner, while the replay lookup above is. So a launch
        -- that repeats a request identity an earlier run already recorded is
        -- refused here by the primary key, and reporting the idempotency key
        -- names the one thing that did not refuse it. Say which attempt held
        -- the identity, so the caller knows a new run needs a new one.
        local recorded, recorded_error = M.row(db, request.attempt_id)
        if recorded_error then return {ok = false, code = "STORAGE", message = recorded_error} end
        if recorded then
            local owner = text(recorded.owner_id) or ""
            if owner ~= request.owner_id then
                return {ok = false, code = "CONFLICT", message = "attempt " .. request.attempt_id .. " is already recorded by owner " .. owner .. "; a new run needs a new request identity"}
            end
            return {ok = false, code = "CONFLICT", message = "attempt " .. request.attempt_id .. " is already recorded under a different request"}
        end
        return {ok = false, code = "CONFLICT", message = "attempt or idempotency key already recorded"}
    end
    if not inserted or integer(inserted.rows_affected) ~= 1 then
        rollback(tx)
        -- A simultaneous replay can see the already-recorded holder through
        -- the session predicate rather than the unique-key error above.
        local existing, existing_error = M.by_key(db, request.owner_id, request.idempotency_key)
        if existing_error then return {ok = false, code = "STORAGE", message = existing_error} end
        if existing and existing.request_digest == digest then return {ok = true, attempt = project(existing)} end
        return {ok = false, code = "CONFLICT", message = "retained session is still held until predecessor cleanup is complete"}
    end
    local _, evidence_err = append(tx, request.attempt_id, 0, "intent.recorded", "capability " .. measured.capability .. " (" .. measured.exit_observation .. "), required " .. request.required_cleanup .. " (" .. request.required_exit_observation .. ")", at)
    if evidence_err then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = evidence_err}
    end
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = "commit intent"}
    end
    local attempt = M.attempt(db, request.attempt_id)
    return {ok = true, attempt = attempt}
end
-- One transition: the state machine decides, evidence is appended, fields
-- are set, all in one transaction.
function M.transition(db: sql.DB, attempt_id: string, update: Update): Result
    local tx, begin_err = db:begin()
    if not tx then return {ok = false, code = "STORAGE", message = "begin transition"} end
    local rows, read_err = tx:query("SELECT * FROM bee_placement_attempts WHERE attempt_id = ?", {attempt_id})
    if read_err or not rows then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = "read attempt"}
    end
    if #rows == 0 then
        rollback(tx)
        return {ok = false, code = "NOT_FOUND", message = "attempt is not recorded"}
    end
    local row = rows[1] :: Row
    local execution = state_of(row.execution_state, "uncertain") :: types.ExecutionState
    local cleanup = state_of(row.cleanup_state, "uncertain") :: types.CleanupState
    local count = integer(row.evidence_count)
    if not count or count < 0 then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = "attempt evidence count is corrupt"}
    end
    if update.expected_execution and execution ~= update.expected_execution then
        rollback(tx)
        return {ok = false, code = "CONFLICT", message = "execution " .. execution .. " is not the expected " .. update.expected_execution}
    end
    if update.execution and update.execution ~= execution then
        if not transitions.execution(execution, update.execution) then
            rollback(tx)
            return {ok = false, code = "CONFLICT", message = "execution " .. execution .. " does not move to " .. update.execution}
        end
        execution = update.execution
    end
    if update.cleanup and update.cleanup ~= cleanup then
        if not transitions.cleanup(cleanup, update.cleanup) then
            rollback(tx)
            return {ok = false, code = "CONFLICT", message = "cleanup " .. cleanup .. " does not move to " .. update.cleanup}
        end
        cleanup = update.cleanup
    end
    local at = M.now()
    local sequence, evidence_err = append(tx, attempt_id, count, update.evidence.kind, update.evidence.detail, at)
    if not sequence then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = evidence_err}
    end
    local assignments: {string} = {"execution_state = ?", "cleanup_state = ?", "evidence_count = ?", "updated_at = ?"}
    local values: {unknown} = {execution, cleanup, sequence, at}
    for name, value in pairs(update.fields or {}) do
        if not name:match("^[a-z_]+$") then
            rollback(tx)
            return {ok = false, code = "STORAGE", message = "invalid field"}
        end
        assignments[#assignments + 1] = name .. " = ?"
        values[#values + 1] = value
    end
    values[#values + 1] = attempt_id
    local _, update_err = tx:execute("UPDATE bee_placement_attempts SET " .. table.concat(assignments, ", ") .. " WHERE attempt_id = ?", values)
    if update_err then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = "update attempt"}
    end
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then
        rollback(tx)
        return {ok = false, code = "STORAGE", message = "commit transition"}
    end
    local attempt, attempt_error = M.attempt(db, attempt_id)
    if attempt_error or not attempt then
        return {ok = false, code = "STORAGE", message = attempt_error or "read transitioned attempt"}
    end
    return {ok = true, attempt = attempt}
end
function M.evidence(db: sql.DB, attempt_id: string, after: integer, limit: integer): (types.EvidencePage?, string?)
    local page = math.floor(limit)
    if page < 1 or page > M.MAX_EVIDENCE_PAGE then page = M.MAX_EVIDENCE_PAGE end
    local rows, err = db:query("SELECT sequence, at, kind, detail FROM bee_placement_evidence WHERE attempt_id = ? AND sequence > ? ORDER BY sequence LIMIT ?",
        {attempt_id, after, page + 1})
    if err or not rows then return nil, "read evidence" end
    local list: {types.Evidence} = {}
    local next_after: integer? = nil
    for index, row in ipairs(rows) do
        if index > page then
            next_after = list[#list].sequence
            break
        end
        local sequence, at, kind, detail = integer(row.sequence), text(row.at), text(row.kind), text(row.detail)
        if not sequence or sequence < 1 or not at or not kind or not detail then return nil, "evidence row is corrupt" end
        list[index] = {sequence = sequence, at = at, kind = kind, detail = detail}
    end
    return {attempt_id = attempt_id, evidence = list, next_after = next_after}, nil
end
return M

-- MIT. Canonical session and work state shares the thread journal, its
-- transaction boundary and owner epoch; queue rows are indexes, not inboxes.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local uuid = require("uuid")
local system = require("system")
local access = require("access")
local transaction = require("transaction")
local thread_owner = require("thread_owner")
local record = require("record")
local observation = require("observation")
local record_types = require("record_types")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
type Result = transaction.Result
type Row = {[string]: unknown}
type Session = {session_ref: string, thread_id: string, workspace_id: string, owner_actor: string, title: string,
    state: string, revision: integer, created_at: string, updated_at: string, route_json: string, context_json: string}
type Work = {work_ref: string, session_ref: string, workspace_id: string, sequence: integer, revision: integer,
    phase: string, input_json: string, input_digest: string, output_schema: string, sender_kind: string, sender_id: string,
    result_json: string?, uncertainty_json: string?, operation_ref: string, created_at: string}
type Turn = {turn_ref: string, session_ref: string, work_ref: string, claim_token: string, owner_epoch: integer,
    input_digest: string, phase: string, checkpoint_json: string?, reserve_record_id: string,
    accept_record_id: string?, settle_record_id: string?, created_at: string}
local MAX_KEY_BYTES = 128
local MAX_REF_BYTES = 256
local MAX_VALUE_BYTES = 65536
local MAX_FEED_PAGE = 64
local MAX_SESSION_SCAN = 64

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function object(value: unknown): Row?
    if type(value) ~= "table" then return nil end
    return value :: Row
end

local function has_only(row: Row, allowed: {[string]: boolean}): boolean
    for key in pairs(row) do
        if type(key) ~= "string" or not allowed[key] then return false end
    end
    return true
end

local function text(value: unknown, maximum: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > maximum or value:find("%c") then return nil end
    return value
end

local function key(value: unknown): string?
    return text(value, MAX_KEY_BYTES)
end

local function ref(value: unknown): string?
    return text(value, MAX_REF_BYTES)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > bounds.MAX_SAFE_INTEGER then return nil end
    return math.floor(value)
end

local function encode(value: unknown, maximum: integer?): (string?, string?)
    return canonical.encode(value, maximum or MAX_VALUE_BYTES, bounds.MAX_JSON_DEPTH)
end

local function digest(value: string): string?
    local measured, hash_error = hash.sha256(value)
    if hash_error or not measured then return nil end
    return measured
end

local function request_identity(operation: string, arguments: unknown): (string?, string?, string?)
    local request_json, encode_error = encode({operation = operation, arguments = arguments})
    if not request_json then return nil, nil, encode_error or "operation arguments are not encodable" end
    local request_digest = digest(request_json)
    if not request_digest then return nil, nil, "measure operation request" end
    return request_json, request_digest, nil
end

local function allocate_id(): (string?, string?)
    local value, id_error = uuid.v7()
    if id_error or not value then return nil, "allocate identifier" end
    return value, nil
end

local function node_id(): (string?, string?)
    local value, node_error = system.node.id()
    if node_error or not value or not text(value, 160) then return nil, "node identity is unavailable" end
    return value, nil
end

local function qualified(prefix: string, node: string, workspace: string, id: string): string
    return prefix .. ":" .. node .. ":" .. workspace .. ":" .. id
end

local function authenticated(actor: string, allow_global: boolean?): (string?, string?, Result?)
    if not access.may_manage_sessions() then return nil, nil, failure("DENIED", "only the Sessions owner may call the journal contract") end
    if not bounds.id(actor) then return nil, nil, failure("DENIED", "caller identity is unavailable") end
    local workspace = access.workspace()
    if not workspace and not allow_global then return nil, nil, failure("DENIED", "Sessions owner has no workspace identity") end
    return actor, workspace, nil
end

local function query_one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): (Row?, string?)
    local rows, query_error = tx:query(statement, params)
    if query_error or not rows then return nil, "read " .. label end
    if #rows > 1 then return nil, label .. " rows are corrupt" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
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

local function work_row(row: Row): (Work?, string?)
    local work_ref, session_ref = text(row.work_ref, MAX_REF_BYTES), text(row.session_ref, MAX_REF_BYTES)
    local workspace, input_json = text(row.workspace_id, 32), type(row.input_json) == "string" and row.input_json or nil
    local input_digest, output_schema = text(row.input_digest, 128), text(row.output_schema, MAX_REF_BYTES)
    local sender_kind, sender_id = text(row.sender_kind, 16), text(row.sender_id, MAX_REF_BYTES)
    local phase = text(row.phase, 32)
    local sequence, revision = integer(row.sequence), integer(row.revision)
    local operation_ref, created_at = text(row.operation_ref, MAX_REF_BYTES), text(row.created_at, 64)
    local result_json: string? = nil
    if row.result_json ~= nil then
        if type(row.result_json) ~= "string" then return nil, "work result is corrupt" end
        result_json = row.result_json :: string
    end
    local uncertainty_json: string? = nil
    if row.uncertainty_json ~= nil then
        if type(row.uncertainty_json) ~= "string" then return nil, "work uncertainty is corrupt" end
        uncertainty_json = row.uncertainty_json :: string
    end
    if not work_ref or not session_ref or not workspace or not input_json or not input_digest or not output_schema
        or (sender_kind ~= "session" and sender_kind ~= "principal") or not sender_id
        or not phase or not sequence or not revision or not operation_ref or not created_at then return nil, "work row is corrupt" end
    return {work_ref = work_ref, session_ref = session_ref, workspace_id = workspace, sequence = sequence,
        revision = revision, phase = phase, input_json = input_json :: string, input_digest = input_digest,
        output_schema = output_schema, sender_kind = sender_kind, sender_id = sender_id, result_json = result_json,
        uncertainty_json = uncertainty_json, operation_ref = operation_ref, created_at = created_at}, nil
end

local function turn_row(row: Row): (Turn?, string?)
    local turn_ref, session_ref, work_ref = text(row.turn_ref, MAX_REF_BYTES), text(row.session_ref, MAX_REF_BYTES), text(row.work_ref, MAX_REF_BYTES)
    local claim_token, input_digest, phase = text(row.claim_token, 128), text(row.input_digest, 128), text(row.phase, 32)
    local owner_epoch = integer(row.owner_epoch)
    local reserve_record_id, created_at = text(row.reserve_record_id, 160), text(row.created_at, 64)
    local checkpoint_json: string? = nil
    if row.checkpoint_json ~= nil then
        if type(row.checkpoint_json) ~= "string" then return nil, "turn checkpoint is corrupt" end
        checkpoint_json = row.checkpoint_json :: string
    end
    local accept_record_id: string? = nil
    if row.accept_record_id ~= nil then
        if type(row.accept_record_id) ~= "string" then return nil, "turn acceptance is corrupt" end
        accept_record_id = row.accept_record_id :: string
    end
    local settle_record_id: string? = nil
    if row.settle_record_id ~= nil then
        if type(row.settle_record_id) ~= "string" then return nil, "turn settlement is corrupt" end
        settle_record_id = row.settle_record_id :: string
    end
    if not turn_ref or not session_ref or not work_ref or not claim_token or not input_digest or not phase or not owner_epoch or owner_epoch < 1
        or not reserve_record_id or not created_at then return nil, "turn row is corrupt" end
    return {turn_ref = turn_ref, session_ref = session_ref, work_ref = work_ref, claim_token = claim_token,
        owner_epoch = owner_epoch, input_digest = input_digest, phase = phase, checkpoint_json = checkpoint_json,
        reserve_record_id = reserve_record_id, accept_record_id = accept_record_id,
        settle_record_id = settle_record_id, created_at = created_at}, nil
end

local function get_session(tx: sql.Transaction, session_ref: string, workspace: string?): (Session?, string?)
    local row, query_error = query_one(tx, "SELECT session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json, context_json " ..
        "FROM bee_sessions WHERE session_ref = ? AND (? IS NULL OR workspace_id = ?)", {session_ref, workspace, workspace}, "session")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return session_row(row)
end

local function get_work(tx: sql.Transaction, work_ref: string, workspace: string?): (Work?, string?)
    local row, query_error = query_one(tx, "SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
        "output_schema, sender_kind, sender_id, result_json, uncertainty_json, operation_ref, created_at FROM bee_session_work WHERE work_ref = ? AND (? IS NULL OR workspace_id = ?)",
        {work_ref, workspace, workspace}, "work")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return work_row(row)
end

local function get_turn(tx: sql.Transaction, turn_ref: string): (Turn?, string?)
    local row, query_error = query_one(tx, "SELECT turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, " ..
        "reserve_record_id, accept_record_id, settle_record_id, created_at FROM bee_session_turns WHERE turn_ref = ?", {turn_ref}, "turn")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    return turn_row(row)
end

local function operation_replay(tx: sql.Transaction, actor: string, workspace: string, operation_key: string,
    operation: string, request_digest: string): (Result?, string?)
    local row, query_error = query_one(tx, "SELECT operation, request_digest, receipt_json FROM bee_session_operations " ..
        "WHERE workspace_id = ? AND owner_actor = ? AND operation_key = ?", {workspace, actor, operation_key}, "operation receipt")
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    if row.operation ~= operation or row.request_digest ~= request_digest then
        return failure("CONFLICT", "operation key already names a different request"), nil
    end
    if type(row.receipt_json) ~= "string" then return nil, "operation receipt is corrupt" end
    local receipt, decode_error = json.decode(row.receipt_json :: string)
    if decode_error or type(receipt) ~= "table" then return nil, "operation receipt cannot be decoded" end
    return transaction.success(receipt, true), nil
end

local function operation_reference(node: string, workspace: string): (string?, string?)
    local id, id_error = allocate_id()
    if not id then return nil, id_error end
    return qualified("bo", node, workspace, id), nil
end

local function save_operation(tx: sql.Transaction, actor: string, workspace: string, operation_key: string,
    operation_ref: string, operation: string, request_digest: string, target_ref: string?, receipt: unknown, committed_at: string): string?
    local receipt_json, encode_error = encode(receipt)
    if not receipt_json then return "encode operation receipt: " .. tostring(encode_error) end
    return execute(tx, "INSERT INTO bee_session_operations (workspace_id, owner_actor, operation_key, operation_ref, operation, " ..
        "request_digest, target_ref, receipt_json, committed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {workspace, actor, operation_key, operation_ref, operation, request_digest, target_ref or sql.NULL, receipt_json, committed_at}, "store operation receipt")
end

local function append_event(tx: sql.Transaction, session: Session, actor: string, operation_ref: string, kind: string,
    subject: string, revision: integer, data: unknown): (string?, integer?, string?)
    local payload_json, payload_error = encode({kind = kind, subject = subject, revision = revision, operation = operation_ref, data = data}, bounds.MAX_RECORD_BYTES - 1024)
    if not payload_json then return nil, nil, "encode journal event: " .. tostring(payload_error) end
    local head, head_error = query_one(tx, "SELECT head_sequence FROM bee_thread_heads WHERE thread_id = ?", {session.thread_id}, "journal head")
    if head_error then return nil, nil, head_error end
    if not head then return nil, nil, "session journal head is missing" end
    local previous = integer(head.head_sequence)
    if previous == nil or previous >= bounds.MAX_SAFE_INTEGER then return nil, nil, "journal sequence is unavailable" end
    local sequence = previous + 1
    local record_id, id_error = transaction.record_id()
    if not record_id then return nil, nil, id_error or "allocate journal event" end
    local now = transaction.now()
    local body: record_types.Observation = {
        type = "extension", event_key = record_id, observed_at = now,
        data = {type = "extension", event_name = "bee.sessions.event", event_revision = "1", payload_json = payload_json},
    }
    local decoded_body, body_error = observation.decode(body)
    if not decoded_body then return nil, nil, "validate journal event: " .. tostring(body_error) end
    local payload: record_types.RecordPayload = {kind = "observation", body = decoded_body}
    local envelope: record_types.RecordEnvelope = {schema_revision = bounds.SCHEMA_REVISION, record_id = record_id,
        thread_id = session.thread_id, sequence = sequence, recorded_at = now, producer_id = actor, source = "bee"}
    local record_json, encode_error = record.encode_parts(envelope, payload)
    if not record_json then return nil, nil, "encode canonical journal record: " .. tostring(encode_error) end
    local insert_error = transaction.insert_record(tx, {record_id = record_id, thread_id = session.thread_id, sequence = sequence,
        kind = "observation", producer_id = actor, source = "bee", event_scope = "sessions", event_key = record_id,
        record_json = record_json, committed_at = now})
    if insert_error then return nil, nil, insert_error end
    return record_id, sequence, nil
end

local function node_and_operation(node: string?, workspace: string): (string?, string?, string?)
    if not node then
        local node_error: string?
        node, node_error = node_id()
        if not node then return nil, nil, node_error or "node identity is unavailable" end
    end
    local operation_ref, reference_error = operation_reference(node :: string, workspace)
    if not operation_ref then return nil, nil, reference_error or "allocate operation reference" end
    return node :: string, operation_ref, nil
end

local function operation_context(tx: sql.Transaction, actor: string, workspace: string, operation_key: string,
    operation: string, arguments: unknown): (string?, Result?, string?)
    local _, request_digest, request_error = request_identity(operation, arguments)
    if not request_digest then return nil, nil, request_error or "encode operation request" end
    local replay, replay_error = operation_replay(tx, actor, workspace, operation_key, operation, request_digest)
    if replay_error then return nil, nil, replay_error end
    if replay then return request_digest, replay, nil end
    return request_digest, nil, nil
end

local function finish_operation(tx: sql.Transaction, actor: string, workspace: string, operation_key: string,
    operation_ref: string, operation: string, request_digest: string, target_ref: string?, receipt: unknown, now: string): Result
    local save_error = save_operation(tx, actor, workspace, operation_key, operation_ref, operation, request_digest, target_ref, receipt, now)
    if save_error then return failure("INTERNAL", save_error) end
    return transaction.success(receipt, false)
end

local function missing_request(): Result
    return failure("INVALID_ARGUMENT", "request must be an object with the exact fields for this operation")
end

local function decode_json(value: string): (unknown, string?)
    local decoded, decode_error = json.decode(value)
    if decode_error then return nil, "stored JSON is corrupt" end
    return decoded :: unknown, nil
end

local function current_epoch(tx: sql.Transaction): (integer?, string?)
    local epoch, owner_error = thread_owner.current(tx)
    if owner_error then return nil, owner_error end
    if not epoch or epoch < 1 then return nil, "thread owner epoch is not established" end
    return epoch, nil
end

function M.session_create(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {operation_key = true, title = true, route = true}) then return missing_request() end
    local operation_key = key(input.operation_key)
    local title = input.title == nil and "Session" or text(input.title, 512)
    local route_json, route_error = encode(input.route or {})
    if not operation_key or not title or not route_json or type(input.route or {}) ~= "table" then
        return failure("INVALID_ARGUMENT", route_error or "operation_key, title or route is invalid")
    end
    local route_digest = digest(route_json)
    if not route_digest then return failure("INTERNAL", "measure pinned session route") end
    local arguments = {title = title, route_digest = route_digest}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller :: string, workspace :: string, operation_key, "session_create", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local node, op_ref, reference_error = node_and_operation(nil, workspace :: string)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local session_id, session_id_error = allocate_id()
        local thread_id, thread_id_error = allocate_id()
        if not session_id or not thread_id then return failure("INTERNAL", session_id_error or thread_id_error or "allocate session identity") end
        local session_ref = qualified("bs", node, workspace :: string, session_id)
        local stored_route: Row = {}
        for name, value in pairs(object(input.route) or {}) do stored_route[name] = value end
        local placement_request = object(stored_route.placement_request)
        if placement_request then
            local retained_request: Row = {}
            for name, value in pairs(placement_request) do retained_request[name] = value end
            retained_request.session_ref = session_ref
            stored_route.placement_request = retained_request
        end
        local stored_route_json, stored_route_error = encode(stored_route)
        if not stored_route_json then return failure("INVALID_ARGUMENT", stored_route_error or "session route is invalid") end
        local now = transaction.now()
        local head_error = transaction.insert_head(tx, {thread_id = thread_id, owner_actor = caller :: string, title = title :: string,
            created_at = now, workspace_id = workspace})
        if head_error then return failure("INTERNAL", head_error) end
        local member_error = transaction.insert_member(tx, thread_id, caller :: string, "owner", 1)
        if member_error then return failure("INTERNAL", member_error) end
        local session_error = execute(tx, "INSERT INTO bee_sessions (session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json) " ..
            "VALUES (?, ?, ?, ?, ?, 'active', 1, ?, ?, ?)", {session_ref, thread_id, workspace, caller, title, now, now, stored_route_json}, "create session")
        if session_error then return failure("INTERNAL", session_error) end
        local session: Session = {session_ref = session_ref, thread_id = thread_id, workspace_id = workspace :: string,
            owner_actor = caller :: string, title = title :: string, state = "active", revision = 1, created_at = now, updated_at = now,
            route_json = stored_route_json :: string, context_json = "{}"}
        local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "session.created", session_ref, 1,
            {title = title, route_digest = route_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append session creation event") end
        local receipt = {session = session_ref, operation = op_ref, state = "active", revision = 1, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, workspace :: string, operation_key, op_ref, "session_create", request_digest :: string, session_ref, receipt, now)
    end)
end

function M.session_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    local session_ref = input and has_only(input, {session = true}) and ref(input.session) or nil
    if not session_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, query_error = get_session(tx, session_ref, workspace :: string)
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, count_error = tx:query("SELECT phase, COUNT(*) AS count, " ..
            "SUM(CASE WHEN uncertainty_json IS NOT NULL THEN 1 ELSE 0 END) AS uncertain " ..
            "FROM bee_session_work WHERE session_ref = ? GROUP BY phase", {session_ref})
        if count_error or not rows then return transaction.storage_failure("count session work") end
        local queued, reserved, accepted, settled, uncertain = 0, 0, 0, 0, 0
        for _, row in ipairs(rows) do
            local phase = text(row.phase, 32)
            local count = integer(row.count)
            if not phase or not count then return failure("INTERNAL", "session work count is corrupt") end
            local uncertain_count = integer(row.uncertain)
            if not uncertain_count then return failure("INTERNAL", "session uncertainty count is corrupt") end
            uncertain = uncertain + uncertain_count
            if phase == "queued" then queued = count
            elseif phase == "reserved" then reserved = count
            elseif phase == "accepted" then accepted = count
            elseif phase == "settled" then settled = count
            else return failure("INTERNAL", "session work phase is corrupt") end
        end
        local head, head_error = query_one(tx, "SELECT head_sequence FROM bee_thread_heads WHERE thread_id = ?", {session.thread_id}, "journal head")
        if head_error then return transaction.storage_failure(head_error) end
        if not head then return failure("INTERNAL", "session journal head is missing") end
        local head_sequence = integer(head.head_sequence)
        if head_sequence == nil then return failure("INTERNAL", "session journal sequence is corrupt") end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local stalled_row, stalled_error = query_one(tx, "SELECT COUNT(*) AS count FROM bee_session_turns " ..
            "WHERE session_ref = ? AND phase IN ('reserved','accepted') AND owner_epoch <> ?", {session_ref, epoch}, "stalled session turns")
        if stalled_error then return transaction.storage_failure(stalled_error) end
        local stalled = stalled_row and integer(stalled_row.count) or 0
        if not stalled then return failure("INTERNAL", "stalled turn count is corrupt") end
        local route, route_error = decode_json(session.route_json)
        if route_error then return failure("INTERNAL", route_error) end
        return transaction.success({session = session.session_ref, title = session.title, state = session.state, route = route,
            revision = session.revision, created_at = session.created_at, updated_at = session.updated_at,
            queued = queued, active = reserved + accepted, settled = settled, uncertain = uncertain, stalled = stalled,
            head_sequence = head_sequence}, false)
    end)
end

function M.session_scan(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {cursor = true, limit = true}) then return missing_request() end
    local cursor = input.cursor == nil and nil or ref(input.cursor)
    local limit = input.limit == nil and MAX_SESSION_SCAN or integer(input.limit)
    if (input.cursor ~= nil and not cursor) or not limit or limit < 1 or limit > MAX_SESSION_SCAN then
        return failure("INVALID_ARGUMENT", "session cursor or scan limit is invalid")
    end
    local page_limit = limit :: integer
    local cursor_parameter = cursor or sql.NULL
    return transaction.read(db, function(tx: sql.Transaction): Result
        local rows, query_error = tx:query("SELECT session_ref FROM bee_sessions " ..
            "WHERE workspace_id = ? AND (? IS NULL OR session_ref > ?) ORDER BY session_ref LIMIT ?",
            {workspace, cursor_parameter, cursor_parameter, page_limit + 1})
        if query_error or not rows then return transaction.storage_failure("scan sessions") end
        local items: {string} = {}
        local count = #rows
        local has_more = count > page_limit
        if has_more then count = page_limit end
        for index = 1, count do
            local session_ref = ref(rows[index].session_ref)
            if not session_ref then return failure("INTERNAL", "session reference is corrupt") end
            items[index] = session_ref
        end
        return transaction.success({items = items, next = has_more and items[#items] or nil}, false)
    end)
end

function M.session_transition(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {session = true, state = true, operation_key = true, expected_revision = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    local target = text(input.state, 32)
    local expected_revision = input.expected_revision == nil and nil or integer(input.expected_revision)
    if input.expected_revision ~= nil and (not expected_revision or expected_revision < 1) then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    if not session_ref or not operation_key or (target ~= "active" and target ~= "suspended" and target ~= "closing" and target ~= "closed") then
        return failure("INVALID_ARGUMENT", "session, operation_key or lifecycle state is invalid")
    end
    local arguments = {session = session_ref, state = target}
    if expected_revision then arguments.expected_revision = expected_revision end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller :: string, workspace :: string, operation_key, "session_transition", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local session, query_error = get_session(tx, session_ref, workspace :: string)
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        if expected_revision and expected_revision ~= session.revision then return failure("CONFLICT", "session revision changed") end
        local allowed = (session.state == "active" and (target == "suspended" or target == "closing"))
            or (session.state == "suspended" and (target == "active" or target == "closing"))
            or (session.state == "closing" and target == "closed")
        if session.state == "closed" then return failure("CONFLICT", "closed sessions cannot change lifecycle") end
        if target == session.state then allowed = true end
        if target == "closed" then
            local unsettled, count_error = query_one(tx, "SELECT COUNT(*) AS count FROM bee_session_work WHERE session_ref = ? AND phase <> 'settled'", {session_ref}, "unsettled work")
            if count_error then return transaction.storage_failure(count_error) end
            if not unsettled or integer(unsettled.count) ~= 0 then return failure("BLOCKED", "session has unsettled work") end
            allowed = session.state == "closing" or session.state == "active" or session.state == "suspended"
        end
        if not allowed then return failure("CONFLICT", "session lifecycle transition is not allowed") end
        local node, op_ref, reference_error = node_and_operation(nil, workspace :: string)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local revision = session.revision
        if target ~= session.state then revision = revision + 1 end
        if target ~= session.state then
            local update_error = execute(tx, "UPDATE bee_sessions SET state = ?, revision = ?, updated_at = ? WHERE session_ref = ? AND revision = ?",
                {target, revision, now, session_ref, session.revision}, "update session lifecycle")
            if update_error then return failure("CONFLICT", update_error) end
        end
        local record_id, sequence = nil, nil
        if target ~= session.state then
            local event_error: string?
            record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "session.state_changed", session_ref,
                revision, {from = session.state, to = target})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append lifecycle event") end
        end
        local receipt = {session = session_ref, operation = op_ref, state = target, revision = revision,
            committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, workspace :: string, operation_key, op_ref, "session_transition", request_digest :: string, session_ref, receipt, now)
    end)
end

local function result_value(value: unknown, expected_schema: string?): (string?, Row?, string?)
    local result = object(value)
    if not result then return nil, nil, "result must be an object" end
    local state = text(result.state, 32)
    if state == "succeeded" then
        if not has_only(result, {state = true, schema = true, value = true, artifacts = true, usage = true}) then return nil, nil, "successful result has unknown fields" end
        local schema = text(result.schema, MAX_REF_BYTES)
        if not schema or result.value == nil then return nil, nil, "successful result requires schema and value" end
        if expected_schema and schema ~= expected_schema then return nil, nil, "result schema does not match the admitted output schema" end
    elseif state == "failed" or state == "cancelled" or state == "expired" or state == "rejected" then
        if not has_only(result, {state = true, error = true, artifacts = true}) then return nil, nil, "unsuccessful result has unknown fields" end
        local fault = object(result.error)
        if not fault or not text(fault.code, 128) or not text(fault.message, 4096) then return nil, nil, "unsuccessful result requires a typed fault" end
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
    local input = object(request)
    if not input or not has_only(input, {session = true, operation_key = true, input = true, output_schema = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    local output_schema = input.output_schema == nil and "bee:Text@1" or text(input.output_schema, MAX_REF_BYTES)
    local input_json, input_error = encode(input.input)
    if not session_ref or not operation_key or not output_schema or input.input == nil or not input_json then
        return failure("INVALID_ARGUMENT", input_error or "session, key, input or output schema is invalid")
    end
    local input_digest = digest(input_json :: string)
    if not input_digest then return failure("INTERNAL", "measure immutable work input") end
    local arguments = {session = session_ref, input = input_json, output_schema = output_schema}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller :: string, workspace :: string, operation_key, "work_send", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local session, session_error = get_session(tx, session_ref :: string, workspace :: string)
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        if session.state == "closing" or session.state == "closed" then return failure("CONFLICT", "session is not accepting work") end
        local node, op_ref, reference_error = node_and_operation(nil, workspace :: string)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local id, id_error = allocate_id()
        if not id then return failure("INTERNAL", id_error or "allocate work reference") end
        local work_ref = qualified("bw", node, workspace :: string, id)
        local now = transaction.now()
        local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "work.queued", work_ref, 1,
            {session = session_ref, input_digest = input_digest, output_schema = output_schema})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work event") end
        local sender_kind = caller:match("^bs:") and "session" or "principal"
        local work_error = execute(tx, "INSERT INTO bee_session_work (work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
            "output_schema, sender_kind, sender_id, result_json, operation_ref, created_at) VALUES (?, ?, ?, ?, 1, 'queued', ?, ?, ?, ?, ?, NULL, ?, ?)",
            {work_ref, session_ref, workspace, sequence, input_json, input_digest, output_schema, sender_kind, caller, op_ref, now}, "enqueue work")
        if work_error then return failure("INTERNAL", work_error) end
        local receipt = {work = work_ref, session = session_ref, operation = op_ref, committed_at = now, sequence = sequence,
            kind = "request", state = "queued", output_schema = output_schema, sender = {kind = sender_kind, id = caller}}
        return finish_operation(tx, caller :: string, workspace :: string, operation_key, op_ref, "work_send", request_digest :: string, work_ref, receipt, now)
    end)
end

local function work_value(work: Work): (Row?, string?)
    local input, input_error = decode_json(work.input_json)
    if input_error then return nil, input_error end
    local value: Row = {work = work.work_ref, session = work.session_ref, sequence = work.sequence, revision = work.revision,
        phase = work.phase, input = input, input_digest = work.input_digest, output_schema = work.output_schema,
        sender = {kind = work.sender_kind, id = work.sender_id}, operation = work.operation_ref,
        created_at = work.created_at}
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

function M.work_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    local work_ref = input and has_only(input, {work = true}) and ref(input.work) or nil
    if not work_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local work, query_error = get_work(tx, work_ref :: string, workspace :: string)
        if query_error then return transaction.storage_failure(query_error) end
        if not work then return failure("NOT_FOUND", "work does not exist") end
        local value, value_error = work_value(work)
        if not value then return failure("INTERNAL", value_error or "decode work") end
        return transaction.success(value, false)
    end)
end

function M.work_scan(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local input = object(request)
    local limit = input and has_only(input, {limit = true}) and (input.limit == nil and MAX_FEED_PAGE or integer(input.limit)) or nil
    if not limit or limit < 1 or limit > MAX_FEED_PAGE then return failure("INVALID_ARGUMENT", "work scan limit is outside its bound") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local rows, query_error = tx:query("SELECT w.work_ref, w.session_ref, w.workspace_id, w.sequence, w.revision, w.phase, w.input_json, w.input_digest, " ..
            "w.output_schema, w.sender_kind, w.sender_id, w.result_json, w.uncertainty_json, w.operation_ref, w.created_at, " ..
            "t.turn_ref, t.claim_token, t.owner_epoch, t.checkpoint_json, s.route_json, s.context_json " ..
            "FROM bee_session_work w JOIN bee_sessions s ON s.session_ref = w.session_ref " ..
            "LEFT JOIN bee_session_turns t ON t.work_ref = w.work_ref AND t.phase IN ('reserved','accepted') " ..
            "WHERE (? IS NULL OR s.workspace_id = ?) AND s.state IN ('active','closing') AND " ..
            "(w.phase IN ('reserved','accepted') OR (w.phase = 'queued' AND w.sequence = " ..
            "(SELECT MIN(q.sequence) FROM bee_session_work q WHERE q.session_ref = w.session_ref AND q.phase = 'queued'))) " ..
            "ORDER BY w.sequence LIMIT ?", {workspace, workspace, limit}, "scan session work")
        if query_error or not rows then return transaction.storage_failure("scan session work") end
        local items: {Row} = {}
        for _, row_value in ipairs(rows) do
            local row = row_value :: Row
            local work, work_error = work_row(row)
            if not work then return failure("INTERNAL", work_error or "decode scanned work") end
            local route_value, route_error = decode_json(tostring(row.route_json or ""))
            if route_error or type(route_value) ~= "table" then return failure("INTERNAL", "session route is corrupt") end
            local item: Row = {work = work.work_ref, session = work.session_ref, state = work.phase,
                sender = {kind = work.sender_kind, id = work.sender_id}, input_digest = work.input_digest,
                output_schema = work.output_schema, route = route_value}
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
                    checkpoint, route_error = decode_json(row.checkpoint_json :: string)
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
        return transaction.success({items = items}, false)
    end)
end

function M.work_uncertain(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
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
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref :: string, claim_token :: string, workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "uncertain turn context is incomplete") end
        if turn.phase ~= "accepted" or work.phase ~= "accepted" then return failure("CONFLICT", "only an accepted turn can be marked uncertain") end
        local request_digest, replay, context_error = operation_context(tx, caller :: string, session.workspace_id,
            operation_key, "work_uncertain", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local now = transaction.now()
        local node, op_ref, reference_error = node_and_operation(nil, session.workspace_id)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local _, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "work.uncertain", work.work_ref,
            work.revision + 1, evidence)
        if not sequence then return failure("INTERNAL", event_error or "append uncertainty event") end
        local update_error = execute(tx, "UPDATE bee_session_work SET uncertainty_json = ?, revision = revision + 1 " ..
            "WHERE work_ref = ? AND phase = 'accepted'", {evidence_json, work.work_ref}, "mark work uncertain")
        if update_error then return failure("CONFLICT", update_error) end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref,
            state = "uncertain", evidence = evidence, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, session.workspace_id, operation_key, op_ref, "work_uncertain",
            request_digest :: string, work.work_ref, receipt, now)
    end)
end

function M.operation_lookup(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    local operation_key = input and has_only(input, {operation_key = true}) and key(input.operation_key) or nil
    if not operation_key then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local row, query_error = query_one(tx, "SELECT operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at " ..
            "FROM bee_session_operations WHERE workspace_id = ? AND owner_actor = ? AND operation_key = ?",
            {workspace, caller, operation_key}, "operation lookup")
        if query_error then return transaction.storage_failure(query_error) end
        if not row then return transaction.success({found = false, operation_key = operation_key}, false) end
        if type(row.receipt_json) ~= "string" then return failure("INTERNAL", "operation receipt is corrupt") end
        local receipt, decode_error = decode_json(row.receipt_json :: string)
        if decode_error then return failure("INTERNAL", decode_error) end
        return transaction.success({found = true, operation_key = operation_key, operation = row.operation,
            operation_ref = row.operation_ref, target = row.target_ref, request_digest = row.request_digest,
            committed_at = row.committed_at, receipt = receipt}, false)
    end)
end

function M.operation_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    local operation_ref = input and has_only(input, {operation = true}) and ref(input.operation) or nil
    if not operation_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local row, query_error = query_one(tx, "SELECT operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at " ..
            "FROM bee_session_operations WHERE workspace_id = ? AND owner_actor = ? AND operation_ref = ?",
            {workspace, caller, operation_ref}, "operation")
        if query_error then return transaction.storage_failure(query_error) end
        if not row then return failure("NOT_FOUND", "operation does not exist") end
        if type(row.receipt_json) ~= "string" then return failure("INTERNAL", "operation receipt is corrupt") end
        local receipt, decode_error = decode_json(row.receipt_json :: string)
        if decode_error then return failure("INTERNAL", decode_error) end
        return transaction.success({found = true, operation_key = row.operation_key, operation = row.operation,
            operation_ref = row.operation_ref, target = row.target_ref, request_digest = row.request_digest,
            committed_at = row.committed_at, receipt = receipt}, false)
    end)
end

local function extension_payload(encoded: string): (Row?, string?, string?)
    local stored, decode_error = record.decode_json(encoded)
    if not stored or stored.kind ~= "observation" then return nil, nil, decode_error or "journal record is not an observation" end
    local body = stored.body :: record_types.Observation
    if body.type ~= "extension" or body.data.type ~= "extension" then return nil, nil, "journal event schema is invalid" end
    local extension = body.data :: record_types.Extension
    if extension.event_name ~= "bee.sessions.event" or extension.event_revision ~= "1" then return nil, nil, "journal event revision is unsupported" end
    local payload, payload_error = json.decode(extension.payload_json)
    if payload_error or type(payload) ~= "table" then return nil, nil, "journal event payload is corrupt" end
    return payload :: Row, body.observed_at, nil
end

function M.feed_read(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {session = true, after_sequence = true, limit = true}) then return missing_request() end
    local session_ref = ref(input.session)
    local cursor = input.after_sequence == nil and 0 or integer(input.after_sequence)
    local limit: integer? = MAX_FEED_PAGE
    if input.limit ~= nil then limit = integer(input.limit) end
    if not session_ref or cursor == nil or not limit or limit < 1 or limit > MAX_FEED_PAGE then
        return failure("INVALID_ARGUMENT", "session, after_sequence or feed limit is invalid")
    end
    local page_limit = limit :: integer
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, query_error = get_session(tx, session_ref, workspace :: string)
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, records_error = tx:query("SELECT record_id, sequence, record_json, committed_at FROM bee_thread_records " ..
            "WHERE thread_id = ? AND event_scope = 'sessions' AND sequence > ? ORDER BY sequence LIMIT ?",
            {session.thread_id, cursor, page_limit + 1})
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
            local payload, observed_at, payload_error = extension_payload(encoded :: string)
            if not payload then return failure("INTERNAL", payload_error or "decode session event") end
            events[#events + 1] = {owner = "threads", id = event_id, schema = "bee.sessions.event@1", sequence = sequence,
                recorded_at = committed_at, observed_at = observed_at,
                kind = payload.kind, subject = payload.subject, revision = payload.revision,
                operation = payload.operation, data = payload.data}
            next_cursor = sequence
        end
        return transaction.success({session = session_ref, events = events, cursor = next_cursor, has_more = has_more}, false)
    end)
end

local TURN_COLUMNS = "turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, " ..
    "reserve_record_id, accept_record_id, settle_record_id, created_at"

function M.turn_reserve(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {session = true, operation_key = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    if not session_ref or not operation_key then return missing_request() end
    local arguments = {session = session_ref}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local session, session_error = get_session(tx, session_ref :: string, workspace)
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local scope_workspace = session.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller :: string, scope_workspace, operation_key, "turn_reserve", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        if session.state ~= "active" and session.state ~= "closing" then
            local receipt = {session = session_ref, turn = nil, state = session.state, operation = op_ref, committed_at = now}
            return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest :: string, session_ref, receipt, now)
        end
        local active_row, active_error = query_one(tx, "SELECT " .. TURN_COLUMNS .. " FROM bee_session_turns " ..
            "WHERE session_ref = ? AND phase IN ('reserved','accepted')", {session_ref}, "active turn")
        if active_error then return transaction.storage_failure(active_error) end
        if active_row then
            local active, decode_error = turn_row(active_row)
            if not active then return failure("INTERNAL", decode_error or "active turn is corrupt") end
            if active.owner_epoch ~= epoch then return failure("UNKNOWN_OUTCOME", "an earlier owner epoch has an unsettled turn") end
            local receipt = {session = session_ref, turn = nil, state = "busy", operation = op_ref, committed_at = now}
            return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest :: string, session_ref, receipt, now)
        end
        local work_row_data, work_error = query_one(tx, "SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, " ..
            "output_schema, sender_kind, sender_id, result_json, operation_ref, created_at FROM bee_session_work " ..
            "WHERE session_ref = ? AND phase = 'queued' ORDER BY sequence LIMIT 1", {session_ref}, "queued work")
        if work_error then return transaction.storage_failure(work_error) end
        if not work_row_data then
            local receipt = {session = session_ref, turn = nil, state = "idle", operation = op_ref, committed_at = now}
            return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest :: string, session_ref, receipt, now)
        end
        local work, decode_error = work_row(work_row_data)
        if not work then return failure("INTERNAL", decode_error or "queued work is corrupt") end
        local turn_id, turn_id_error = allocate_id()
        local claim, claim_error = allocate_id()
        if not turn_id or not claim then return failure("INTERNAL", turn_id_error or claim_error or "allocate turn claim") end
        local turn_ref = qualified("bturn", node :: string, workspace :: string, turn_id)
        local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "turn.reserved", work.work_ref,
            work.revision + 1, {turn = turn_ref, input_digest = work.input_digest, owner_epoch = epoch})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn reservation") end
        local insert_error = execute(tx, "INSERT INTO bee_session_turns (turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, " ..
            "checkpoint_json, reserve_record_id, accept_record_id, settle_record_id, created_at) " ..
            "VALUES (?, ?, ?, ?, ?, ?, 'reserved', NULL, ?, NULL, NULL, ?)",
            {turn_ref, session_ref, work.work_ref, claim, epoch, work.input_digest, record_id, now}, "reserve turn")
        if insert_error then return failure("CONFLICT", insert_error) end
        local work_update_error = execute(tx, "UPDATE bee_session_work SET phase = 'reserved', revision = revision + 1 " ..
            "WHERE work_ref = ? AND phase = 'queued'", {work.work_ref}, "mark work reserved")
        if work_update_error then return failure("CONFLICT", work_update_error) end
        local receipt = {session = session_ref, work = work.work_ref, turn = turn_ref, claim = claim,
            input_digest = work.input_digest, owner_epoch = epoch, state = "reserved", operation = op_ref,
            committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_reserve", request_digest :: string, work.work_ref, receipt, now)
    end)
end

function M.turn_recover(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local input = object(request)
    if not input or not has_only(input, {turn = true, operation_key = true}) then return missing_request() end
    local turn_ref, operation_key = ref(input.turn), key(input.operation_key)
    if not turn_ref or not operation_key then return missing_request() end
    local arguments = {turn = turn_ref}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local turn, turn_error = get_turn(tx, turn_ref :: string)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn then return failure("NOT_FOUND", "turn does not exist") end
        if turn.phase == "settled" then return failure("CONFLICT", "settled turn cannot be recovered") end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local session, session_error = get_session(tx, turn.session_ref, workspace)
        if session_error then return transaction.storage_failure(session_error) end
        if not session then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller :: string, scope_workspace,
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
            local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "turn.recovered", turn.work_ref,
                turn.owner_epoch + 1, {turn = turn.turn_ref, previous_epoch = turn.owner_epoch, owner_epoch = epoch})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn recovery") end
            local update_error = execute(tx, "UPDATE bee_session_turns SET claim_token = ?, owner_epoch = ? WHERE turn_ref = ? AND phase IN ('reserved','accepted')",
                {claim_token, epoch, turn.turn_ref}, "recover turn claim")
            if update_error then return failure("CONFLICT", update_error) end
            local receipt = {session = turn.session_ref, work = turn.work_ref, turn = turn.turn_ref, claim = claim_token,
                input_digest = turn.input_digest, owner_epoch = epoch, state = turn.phase, operation = op_ref,
                committed_at = now, sequence = sequence}
            return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_recover",
                request_digest :: string, turn.work_ref, receipt, now)
        end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local receipt = {session = turn.session_ref, work = turn.work_ref, turn = turn.turn_ref, claim = claim_token,
            input_digest = turn.input_digest, owner_epoch = epoch, state = turn.phase, operation = op_ref, committed_at = now}
        return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_recover",
            request_digest :: string, turn.work_ref, receipt, now)
    end)
end

local function claimed_turn(tx: sql.Transaction, turn_ref: string, claim_token: string, workspace: string?): (Turn?, Work?, Session?, Result?)
    local turn, turn_error = get_turn(tx, turn_ref)
    if turn_error then return nil, nil, nil, transaction.storage_failure(turn_error) end
    if not turn then return nil, nil, nil, failure("NOT_FOUND", "turn does not exist") end
    if turn.claim_token ~= claim_token then return nil, nil, nil, failure("DENIED", "turn claim is invalid") end
    local epoch, epoch_error = current_epoch(tx)
    if not epoch then return nil, nil, nil, failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
    if turn.owner_epoch ~= epoch then return nil, nil, nil, failure("STALE", "turn belongs to an earlier owner epoch") end
    local session, session_error = get_session(tx, turn.session_ref, workspace)
    if session_error then return nil, nil, nil, transaction.storage_failure(session_error) end
    if not session then return nil, nil, nil, failure("NOT_FOUND", "turn session does not exist") end
    local work, work_error = get_work(tx, turn.work_ref, session.workspace_id)
    if work_error then return nil, nil, nil, transaction.storage_failure(work_error) end
    if not work then return nil, nil, nil, failure("NOT_FOUND", "turn work does not exist") end
    return turn, work, session, nil
end

function M.turn_pull(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
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
        local checkpoint: unknown = nil
        if turn.checkpoint_json then
            checkpoint, route_error = decode_json(turn.checkpoint_json)
            if route_error then return failure("INTERNAL", route_error) end
        end
        return transaction.success({session = session.session_ref, work = work.work_ref, turn = turn.turn_ref,
            claim = turn.claim_token, owner_epoch = turn.owner_epoch, input = input_value, input_digest = turn.input_digest,
            output_schema = work.output_schema, sender = {kind = work.sender_kind, id = work.sender_id},
            route = route_value, checkpoint = checkpoint, context = context_value, phase = turn.phase}, false)
    end)
end

function M.turn_accept(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
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
        local turn_identity, turn_error = get_turn(tx, turn_ref :: string)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn_identity then return failure("NOT_FOUND", "turn does not exist") end
        local session_identity, session_error = get_session(tx, turn_identity.session_ref, workspace)
        if session_error then return transaction.storage_failure(session_error) end
        if not session_identity then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session_identity.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller :: string, scope_workspace, operation_key, "turn_accept", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref :: string, claim_token :: string, scope_workspace)
        if claim_error then return claim_error end
        if not turn or not work or not session then return failure("INTERNAL", "turn acceptance context is incomplete") end
        if turn.phase ~= "reserved" or work.phase ~= "reserved" then return failure("CONFLICT", "only a reserved turn can be accepted") end
        if input_digest ~= turn.input_digest or input_digest ~= work.input_digest then return failure("CONFLICT", "accepted input digest does not match the frozen work") end
        local node, op_ref, reference_error = node_and_operation(nil, scope_workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "turn.accepted", work.work_ref,
            work.revision + 1, {turn = turn.turn_ref, input_digest = input_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append turn acceptance") end
        local update_turn_error = execute(tx, "UPDATE bee_session_turns SET phase = 'accepted', checkpoint_json = ?, accept_record_id = ? " ..
            "WHERE turn_ref = ? AND owner_epoch = ? AND phase = 'reserved'", {checkpoint_json, record_id, turn.turn_ref, turn.owner_epoch}, "accept turn")
        if update_turn_error then return failure("CONFLICT", update_turn_error) end
        local update_work_error = execute(tx, "UPDATE bee_session_work SET phase = 'accepted', revision = revision + 1 " ..
            "WHERE work_ref = ? AND phase = 'reserved'", {work.work_ref}, "mark work accepted")
        if update_work_error then return failure("CONFLICT", update_work_error) end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref, state = "accepted",
            operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "turn_accept", request_digest :: string, work.work_ref, receipt, now)
    end)
end

function M.work_settle(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
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
        local turn_identity, turn_error = get_turn(tx, turn_ref :: string)
        if turn_error then return transaction.storage_failure(turn_error) end
        if not turn_identity then return failure("NOT_FOUND", "turn does not exist") end
        local session_identity, session_error = get_session(tx, turn_identity.session_ref, workspace)
        if session_error then return transaction.storage_failure(session_error) end
        if not session_identity then return failure("NOT_FOUND", "turn session does not exist") end
        local scope_workspace = session_identity.workspace_id
        local request_digest, replay, context_error = operation_context(tx, caller :: string, scope_workspace, operation_key, "work_settle", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local turn, work, session, claim_error = claimed_turn(tx, turn_ref :: string, claim_token :: string, scope_workspace)
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
        local record_id, sequence, event_error = append_event(tx, session, caller :: string, op_ref, "work.settled", work.work_ref,
            next_revision, {turn = turn.turn_ref, state = checked_result.state, result_digest = result_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work settlement") end
        local turn_error = execute(tx, "UPDATE bee_session_turns SET phase = 'settled', settle_record_id = ? " ..
            "WHERE turn_ref = ? AND owner_epoch = ? AND phase = 'accepted'", {record_id, turn.turn_ref, turn.owner_epoch}, "settle turn")
        if turn_error then return failure("CONFLICT", turn_error) end
        local work_error = execute(tx, "UPDATE bee_session_work SET phase = 'settled', revision = ?, result_json = ? " ..
            "WHERE work_ref = ? AND phase = 'accepted'", {next_revision, checked_json, work.work_ref}, "settle work")
        if work_error then return failure("CONFLICT", work_error) end
        if context_json then
            local context_error = execute(tx, "UPDATE bee_sessions SET context_json = ?, updated_at = ? WHERE session_ref = ?",
                {context_json, now, session.session_ref}, "save session context")
            if context_error then return failure("INTERNAL", context_error) end
        end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref, phase = "settled",
            result = checked_result, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller :: string, scope_workspace, operation_key, op_ref, "work_settle", request_digest :: string, work.work_ref, receipt, now)
    end)
end

return M

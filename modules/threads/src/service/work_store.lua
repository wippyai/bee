-- MIT. Canonical session and work state shares the thread journal, its
-- transaction boundary and owner epoch; queue rows are indexes, not inboxes.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local uuid = require("uuid")
local system = require("system")
local access = require("access")
local journal = require("journal")
local transaction = require("transaction")
local thread_owner = require("thread_owner")
local reader = require("reader")
local record = require("record")
local observation = require("observation")
local record_types = require("record_types")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local budget_values = require("budget_values")
local canonical = require("canonical")
local time = require("time")
local M = {}
type Result = transaction.Result
type Row = {[string]: unknown}
type Session = journal.Session
type Work = journal.Work
type Turn = journal.Turn
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
    return value
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

local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end

local function encode(value: unknown, maximum: integer?): (string?, string?)
    return canonical.encode(value, maximum or MAX_VALUE_BYTES, record_bounds.MAX_JSON_DEPTH)
end

local function budget_json(value: unknown): (string?, string?)
    if value == nil then return "{}", nil end
    local selected, err = budget_values.decode(value)
    if not selected then return nil, err end
    return encode(selected)
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

local function target_workspace(address: string, home: string?): string?
    if not home then return nil end
    local target = address:match("^[a-z]+:[^:]+:([^:]+):[^:]+$")
    if target and target ~= home and access.may_list_workspace(target) then return target end
    return home
end

local function mutation_workspace(address: string, home: string?, operation: string): string?
    local target = address:match("^[a-z]+:[^:]+:([^:]+):[^:]+$")
    if target and target ~= home then
        if access.may_use_sessions_workspace(target, operation) then return target end
        return nil
    end
    return home
end

local function operation_replay(tx: sql.Transaction, actor: string, workspace: string, operation_key: string,
    operation: string, request_digest: string): (Result?, string?)
    local row, query_error = journal.operation_receipt(tx, workspace, actor, operation_key)
    if query_error then return nil, query_error end
    if not row then return nil, nil end
    if row.operation ~= operation or row.request_digest ~= request_digest then
        return failure("CONFLICT", "operation key already names a different request"), nil
    end
    if type(row.receipt_json) ~= "string" then return nil, "operation receipt is corrupt" end
    local receipt, decode_error = json.decode(row.receipt_json)
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
    return journal.insert_operation(tx, workspace, actor, operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at)
end

local function append_event(tx: sql.Transaction, session: Session, actor: string, operation_ref: string, kind: string,
    subject: string, revision: integer, data: unknown): (string?, integer?, string?)
    local payload_json, payload_error = encode({kind = kind, subject = subject, revision = revision, operation = operation_ref, data = data}, record_bounds.MAX_RECORD_BYTES - 1024)
    if not payload_json then return nil, nil, "encode journal event: " .. tostring(payload_error) end
    local head, head_error = journal.head(tx, session.thread_id)
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
    local envelope: record_types.RecordEnvelope = {schema_revision = record_bounds.SCHEMA_REVISION, record_id = record_id,
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
    local operation_ref, reference_error = operation_reference(node, workspace)
    if not operation_ref then return nil, nil, reference_error or "allocate operation reference" end
    return node, operation_ref, nil
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
    return decoded, nil
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
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {operation_key = true, title = true, route = true, thread_id = true}) then return missing_request() end
    local operation_key = key(input.operation_key)
    local title = input.title == nil and "Session" or text(input.title, 512)
    local route_json, route_error = encode(input.route or {})
    if not operation_key or not title or not route_json or type(input.route or {}) ~= "table" then
        return failure("INVALID_ARGUMENT", route_error or "operation_key, title or route is invalid")
    end
    local route_digest = digest(route_json)
    if not route_digest then return failure("INTERNAL", "measure pinned session route") end
    local existing_thread = input.thread_id == nil and nil or text(input.thread_id, 160)
    if input.thread_id ~= nil and not existing_thread then return missing_request() end
    local arguments = {title = title, route_digest = route_digest, thread_id = existing_thread}
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace, operation_key, "session_create", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local node, op_ref, reference_error = node_and_operation(nil, workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local session_id, session_id_error = allocate_id()
        local thread_id, thread_id_error = allocate_id()
        if existing_thread then thread_id = existing_thread end
        if not session_id or not thread_id then return failure("INTERNAL", session_id_error or thread_id_error or "allocate session identity") end
        local session_ref = qualified("bs", node, workspace, session_id)
        local stored_route: Row = {}
        for name, value in pairs(object(input.route) or {}) do stored_route[name] = value end
        stored_route.session_ref = session_ref
        stored_route.thread_id = thread_id
        stored_route.owner_id = caller
        stored_route.workspace_id = workspace
        stored_route.action_id = session_ref
        local stored_route_json, stored_route_error = encode(stored_route)
        if not stored_route_json then return failure("INVALID_ARGUMENT", stored_route_error or "session route is invalid") end
        local now = transaction.now()
        if existing_thread then
            local head, head_error = journal.interactive_thread(tx, existing_thread)
            if head_error then return transaction.storage_failure(head_error) end
            if not head or head.workspace_id ~= workspace then return failure("DENIED", "interactive session requires its workspace thread") end
            local member, member_error = reader.member(tx, existing_thread, caller)
            if member_error then return transaction.storage_failure(member_error) end
            if not member or not member.active then
                local stable, alias_error = reader.app_live_stable(tx, caller)
                if alias_error then return transaction.storage_failure(alias_error) end
                if stable then member, member_error = reader.app_family_member(tx, existing_thread, stable) end
                if member_error then return transaction.storage_failure(member_error) end
            end
            if not member or not member.active or (member.role ~= "owner" and member.role ~= "participant") then
                return failure("DENIED", "interactive session requires active participant membership in its workspace thread")
            end
        else
            local head_error = transaction.insert_head(tx, {thread_id = thread_id, owner_actor = caller, title = title,
                created_at = now, workspace_id = workspace})
            if head_error then return failure("INTERNAL", head_error) end
            local member_error = transaction.insert_member(tx, thread_id, caller, "owner", 1)
            if member_error then return failure("INTERNAL", member_error) end
        end
        local peer_error = transaction.insert_member(tx, thread_id, session_ref, "participant", 1)
        if peer_error then return failure("INTERNAL", peer_error) end
        local session_error = journal.insert_session(tx, session_ref, thread_id, workspace, caller, title, now, stored_route_json)
        if session_error then return failure("INTERNAL", session_error) end
        local session: Session = {session_ref = session_ref, thread_id = thread_id, workspace_id = workspace,
            owner_actor = caller, title = title, state = "active", revision = 1, created_at = now, updated_at = now,
            route_json = stored_route_json, context_json = "{}"}
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "session.created", session_ref, 1,
            {title = title, route_digest = route_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append session creation event") end
        local receipt = {session = session_ref, operation = op_ref, state = "active", revision = 1, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "session_create", request_digest, session_ref, receipt, now)
    end)
end

function M.session_attach(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {session = true, attempt_id = true, operation_key = true}) then return missing_request() end
    local session_ref, attempt, operation_key = ref(input.session), text(input.attempt_id, 160), key(input.operation_key)
    if not session_ref or not attempt or not operation_key then return missing_request() end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local session, session_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if session_error then return transaction.storage_failure(session_error) end
        if not session or session.owner_actor ~= caller then return failure("DENIED", "interactive attachment belongs to its admitted owner") end
        local arguments = {session = session_ref, attempt_id = attempt}
        local request_digest, replay, context_error = operation_context(tx, caller, session.workspace_id, operation_key, "session_attach", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local route_value, route_error = decode_json(session.route_json)
        local route = object(route_value)
        if route_error or not route or route.delivery ~= "hook" then return failure("CONFLICT", "only interactive sessions attach a native window") end
        if session.state ~= "active" and session.state ~= "suspended" then return failure("CONFLICT", "sealed sessions cannot attach a window") end
        route.native_attempt_id = attempt
        local route_json, encode_error = encode(route)
        if not route_json then return failure("INTERNAL", encode_error or "encode attached route") end
        local node, op_ref, reference_error = node_and_operation(nil, session.workspace_id)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "allocate attachment operation") end
        local now = transaction.now()
        local _, sequence, event_error = append_event(tx, session, caller, op_ref, "session.attached", session_ref, session.revision + 1, {attempt_id = attempt})
        if not sequence then return failure("INTERNAL", event_error or "append attachment") end
        local update_error = journal.attach_session(tx, route_json, now, session_ref)
        if update_error then return failure("INTERNAL", update_error) end
        return finish_operation(tx, caller, session.workspace_id, operation_key, op_ref, "session_attach", request_digest, session_ref, {session = session_ref, operation = op_ref, attempt_id = attempt}, now)
    end)
end

local function consumption(tx: sql.Transaction, session: string): (Row?, string?)
    local row, err = journal.consumption(tx, session)
    if not row then return nil, err or "session consumption is missing" end
    local started, steps, tools, tokens = integer(row.budget_started_at_ms), integer(row.provider_steps), integer(row.tool_calls), integer(row.tokens)
    if not started or not steps or not tools or not tokens then return nil, "session consumption is corrupt" end
    return {provider_steps = steps, tool_calls = tools, tokens = tokens, wall_time_ms = started > 0 and math.max(0, now_ms() - started) or 0}, nil
end

function M.session_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    local session_ref = input and has_only(input, {session = true}) and ref(input.session) or nil
    if not session_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local session, query_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        local rows, count_error = journal.work_counts(tx, session_ref)
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
        local head, head_error = journal.head(tx, session.thread_id)
        if head_error then return transaction.storage_failure(head_error) end
        if not head then return failure("INTERNAL", "session journal head is missing") end
        local head_sequence = integer(head.head_sequence)
        if head_sequence == nil then return failure("INTERNAL", "session journal sequence is corrupt") end
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "owner epoch is unavailable") end
        local recovery_row, recovery_error = journal.unreconciled_turns(tx, session_ref, epoch)
        if recovery_error then return transaction.storage_failure(recovery_error) end
        local recovery_blocked = recovery_row and integer(recovery_row.count) or 0
        if not recovery_blocked then return failure("INTERNAL", "unreconciled turn count is corrupt") end
        local route_value, route_error = decode_json(session.route_json)
        local route = object(route_value)
        if route_error or not route then return failure("INTERNAL", "session route is corrupt") end
        local supervision = object(route.supervision)
        local quiet_period = supervision and integer(supervision.quiet_period_ms) or 60000
        if not quiet_period or quiet_period < 1 then return failure("INTERNAL", "session quiet period is corrupt") end
        local last_rows, last_error = journal.last_result(tx, session_ref)
        if last_error or not last_rows then return transaction.storage_failure("read last session result") end
        local last_result: Row? = nil
        if #last_rows == 1 then
            local last = last_rows[1]
            local decoded, decode_error = decode_json(tostring(last.result_json or ""))
            local result = object(decoded)
            if decode_error or not result then return failure("INTERNAL", "last session result is corrupt") end
            local value = object(result.value)
            local fault = object(result.error)
            local summary = value and text(value.text, 65536) or fault and text(fault.message, 16384) or tostring(result.state)
            last_result = {work = last.work_ref, outcome = result.state, summary = (summary or ""):sub(1, 4096), at = last.created_at}
        end
        local first, first_error = journal.first_work(tx, session_ref)
        if first_error then return transaction.storage_failure(first_error) end
        local title = session.title
        if first then
            local decoded, decode_error = decode_json(tostring(first.input_json or ""))
            if decode_error then return failure("INTERNAL", "first session work is corrupt") end
            local input = object(decoded)
            local prompt = type(decoded) == "string" and decoded or input and text(input.text, 16384)
            if prompt then
                local line = prompt:match("[^\r\n]+")
                if line then title = tostring(session.title) .. " · " .. line:gsub("%c", " "):sub(1, 160) end
            end
        end
        local active_turn, turn_error = journal.session_activity(tx, session_ref)
        if turn_error then return transaction.storage_failure(turn_error) end
        local activity = "idle"
        if queued > 0 or reserved + accepted > 0 then activity = "working" end
        if uncertain > 0 or recovery_blocked > 0 then activity = "blocked" end
        local activity_evidence: Row? = nil
        if activity == "working" and active_turn and active_turn.phase == "accepted"
            and integer(active_turn.owner_epoch) == epoch then
            local last_progress_at = integer(active_turn.last_progress_at_ms)
            if last_progress_at == nil or last_progress_at < 1 then
                activity = "blocked"
            else
                local progress_at: integer = last_progress_at
                local quiet_for = math.max(0, now_ms() - progress_at)
                if quiet_for >= quiet_period then
                    activity = "stalled"
                    activity_evidence = {kind = "quiet", turn = active_turn.turn_ref,
                        last_progress_at_ms = last_progress_at, quiet_period_ms = quiet_period, quiet_for_ms = quiet_for}
                end
            end
        end
        local used, usage_error = consumption(tx, session_ref)
        if not used then return failure("INTERNAL", usage_error or "session consumption is unavailable") end
        local execution_running = accepted > 0 and recovery_blocked == 0
        return transaction.success({session = session.session_ref, thread_ref = session.thread_id, workspace = session.workspace_id,
            active_turn = active_turn and {turn = active_turn.turn_ref, claim = active_turn.claim_token, work = active_turn.work_ref,
                owner_epoch = active_turn.owner_epoch, phase = active_turn.phase, last_progress_at_ms = active_turn.last_progress_at_ms} or nil,
            last_result = last_result, title = title, state = session.state, route = route,
            revision = session.revision, created_at = session.created_at, updated_at = session.updated_at,
            queued = queued, active = reserved + accepted, execution_running = execution_running,
            settled = settled, uncertain = uncertain, recovery_blocked = recovery_blocked,
            activity = activity, activity_evidence = activity_evidence, budget_consumption = used,
            head_sequence = head_sequence}, false)
    end)
end

function M.node_summary(db: sql.DB, _: string, request: unknown): Result
    local input = object(request)
    if not input or next(input) ~= nil then return failure("INVALID_ARGUMENT", "node summary accepts an empty object") end
    if not access.may_summarize_sessions() then return failure("DENIED", "caller may not summarize node sessions") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local epoch, epoch_error = current_epoch(tx)
        if not epoch then return failure("UNAVAILABLE", epoch_error or "thread owner epoch is unavailable") end
        local rows, count_error = journal.executing_sessions(tx, epoch)
        if count_error or not rows or #rows ~= 1 then return transaction.storage_failure("count node sessions") end
        local count = integer(rows[1].count)
        if not count or count < 0 then return failure("INTERNAL", "node session count is corrupt") end
        return transaction.success({running_sessions = count}, false)
    end)
end

function M.session_scan(db: sql.DB, actor: string, request: unknown): Result
    local _, workspace, denied = authenticated(actor)
    if denied then return denied end
    local workspace = assert(workspace)
    local input = object(request)
    if not input or not has_only(input, {cursor = true, limit = true, workspace = true}) then return missing_request() end
    local cursor = input.cursor == nil and nil or ref(input.cursor)
    local limit: integer? = input.limit == nil and MAX_SESSION_SCAN or integer(input.limit)
    if (input.cursor ~= nil and not cursor) or not limit or limit < 1 or limit > MAX_SESSION_SCAN then
        return failure("INVALID_ARGUMENT", "session cursor or scan limit is invalid")
    end
    local selected_workspace = input.workspace == nil and nil or text(input.workspace, 32)
    if input.workspace ~= nil and (not selected_workspace or (selected_workspace ~= workspace and not access.may_list_workspace(selected_workspace))) then return failure("DENIED", "workspace visibility requires a host grant") end
    local page_limit = limit
    return transaction.read(db, function(tx: sql.Transaction): Result
        local homes, homes_error = journal.workspaces(tx)
        if homes_error or not homes then return transaction.storage_failure("read session workspaces") end
        local homes_to_scan: {string} = {}
        for _, row in ipairs(homes) do
            local home = text(row.workspace_id, 32)
            if home and (selected_workspace == nil or home == selected_workspace)
                and (home == workspace or access.may_list_workspace(home)) then
                homes_to_scan[#homes_to_scan + 1] = home
            end
        end
        if #homes_to_scan == 0 then return transaction.success({items = {}}, false) end
        local rows, query_error = journal.scan_sessions(tx, homes_to_scan, cursor, page_limit + 1)
        if query_error or not rows then return transaction.storage_failure("scan sessions") end
        local items: {string} = {}
        local count = #rows
        local has_more = count > page_limit
        if has_more then count = page_limit end
        for index = 1, count do
            local session_ref = ref(rows[index].session_ref)
            if not session_ref then return failure("INTERNAL", "session reference is corrupt") end
            local home = text(rows[index].workspace_id, 32)
            if home == workspace or (home and access.may_list_workspace(home)) then items[#items + 1] = session_ref end
        end
        local last_scanned = count > 0 and ref(rows[count].session_ref) or nil
        return transaction.success({items = items, next = has_more and last_scanned or nil}, false)
    end)
end

function M.session_transition(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
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
    workspace = mutation_workspace(session_ref, workspace, "close")
    if not workspace then return failure("DENIED", "session control requires a host workspace grant") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local request_digest, replay, context_error = operation_context(tx, caller, workspace, operation_key, "session_transition", arguments)
        if context_error then return failure("INTERNAL", context_error) end
        if replay then return replay end
        local session, query_error = journal.session(tx, session_ref, target_workspace(session_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not session then return failure("NOT_FOUND", "session does not exist") end
        if expected_revision and expected_revision ~= session.revision then return failure("CONFLICT", "session revision changed") end
        local allowed = (session.state == "active" and (target == "suspended" or target == "closing"))
            or (session.state == "suspended" and (target == "active" or target == "closing"))
            or (session.state == "closing" and target == "closed")
        if session.state == "closed" then return failure("CONFLICT", "closed sessions cannot change lifecycle") end
        if target == session.state then allowed = true end
        if target == "closed" then
            local unsettled, count_error = journal.unsettled_work(tx, session_ref)
            if count_error then return transaction.storage_failure(count_error) end
            if not unsettled or integer(unsettled.count) ~= 0 then return failure("BLOCKED", "session has unsettled work") end
            allowed = session.state == "closing" or session.state == "active" or session.state == "suspended"
        end
        if not allowed then return failure("CONFLICT", "session lifecycle transition is not allowed") end
        local node, op_ref, reference_error = node_and_operation(nil, workspace)
        if not node or not op_ref then return failure("UNAVAILABLE", reference_error or "cannot allocate operation reference") end
        local now = transaction.now()
        local revision = session.revision
        if target ~= session.state then revision = revision + 1 end
        if target ~= session.state then
            local update_error = journal.transition_session(tx, target, revision, now, session_ref, session.revision)
            if update_error then return failure("CONFLICT", update_error) end
        end
        local record_id, sequence = nil, nil
        if target ~= session.state then
            local event_error: string?
            record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "session.state_changed", session_ref,
                revision, {from = session.state, to = target})
            if not record_id or not sequence then return failure("INTERNAL", event_error or "append lifecycle event") end
        end
        local receipt = {session = session_ref, operation = op_ref, state = target, revision = revision,
            committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "session_transition", request_digest, session_ref, receipt, now)
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
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "work.queued", work_ref, 1,
            {session = session_ref, input_digest = input_digest, output_schema = output_schema, input = input.input,
                sender = {kind = caller:match("^bs:") and "session" or "principal", id = caller}})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work event") end
        local sender_kind = caller:match("^bs:") and "session" or "principal"
        local work_error = journal.insert_work(tx, work_ref, session_ref, workspace, sequence, input_json, input_digest, output_schema, sender_kind, caller, op_ref, now, selected_budget_json)
        if work_error then return failure("INTERNAL", work_error) end
        local receipt = {work = work_ref, session = session_ref, operation = op_ref, committed_at = now, sequence = sequence,
            kind = "request", state = "queued", output_schema = output_schema, sender = {kind = sender_kind, id = caller}}
        return finish_operation(tx, caller, workspace, operation_key, op_ref, "work_send", request_digest, work_ref, receipt, now)
    end)
end

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

function M.work_describe(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor)
    if denied then return denied end
    local caller = assert(caller)
    local workspace = assert(workspace)
    local input = object(request)
    local work_ref = input and has_only(input, {work = true}) and ref(input.work) or nil
    if not work_ref then return missing_request() end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local work, query_error = journal.work(tx, work_ref, target_workspace(work_ref, workspace))
        if query_error then return transaction.storage_failure(query_error) end
        if not work then return failure("NOT_FOUND", "work does not exist") end
        local value, value_error = work_value(work)
        if not value then return failure("INTERNAL", value_error or "decode work") end
        local execution, execution_error = journal.work_execution(tx, work_ref)
        if execution_error then return transaction.storage_failure(execution_error) end
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
                    if checkpoint_error then return failure("INTERNAL", checkpoint_error) end
                    value.checkpoint = checkpoint
                end
            end
        end
        return transaction.success(value, false)
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
    local caller = assert(caller)
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
    local caller = assert(caller)
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
        local rows, records_error = journal.feed(tx, session.thread_id, cursor, page_limit + 1)
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
            events[#events + 1] = {owner = "threads", id = event_id, schema = "bee.sessions.event@1", sequence = sequence,
                recorded_at = committed_at, observed_at = observed_at,
                kind = payload.kind, subject = payload.subject, revision = payload.revision,
                operation = payload.operation, data = payload.data}
            next_cursor = sequence
        end
        return transaction.success({session = session_ref, events = events, cursor = next_cursor, has_more = has_more}, false)
    end)
end


function M.turn_reserve(db: sql.DB, actor: string, request: unknown): Result
    local caller, workspace, denied = authenticated(actor, true)
    if denied then return denied end
    local caller = assert(caller)
    local input = object(request)
    if not input or not has_only(input, {session = true, operation_key = true}) then return missing_request() end
    local session_ref, operation_key = ref(input.session), key(input.operation_key)
    if not session_ref or not operation_key then return missing_request() end
    local arguments = {session = session_ref}
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
        local work_row_data, work_error = journal.queued_work(tx, session_ref)
        if work_error then return transaction.storage_failure(work_error) end
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
    local caller = assert(caller)
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
        local steps, tools, tokens = 0, 0, 0
        if data.type == "turn.signal" and data.phase == "started" then steps = 1
        elseif data.type == "tool.call" then tools = 1
        elseif data.type == "turn.signal" and data.phase == "ended" and data.usage then
            tokens = math.floor(math.min(bounds.MAX_SAFE_INTEGER, (data.usage.input_tokens or 0) + (data.usage.output_tokens or 0)))
        end
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
        local record_id, sequence, event_error = append_event(tx, session, caller, op_ref, "work.settled", work.work_ref,
            next_revision, {turn = turn.turn_ref, state = checked_result.state, result_digest = result_digest})
        if not record_id or not sequence then return failure("INTERNAL", event_error or "append work settlement") end
        local turn_error = journal.settle_turn(tx, record_id, turn.turn_ref, turn.owner_epoch)
        if turn_error then return failure("CONFLICT", turn_error) end
        local work_error = journal.settle_work(tx, next_revision, checked_json, work.work_ref)
        if work_error then return failure("CONFLICT", work_error) end
        if context_json then
            local context_error = journal.save_context(tx, context_json, now, session.session_ref)
            if context_error then return failure("INTERNAL", context_error) end
        end
        local receipt = {session = session.session_ref, work = work.work_ref, turn = turn.turn_ref, phase = "settled",
            result = checked_result, operation = op_ref, committed_at = now, sequence = sequence}
        return finish_operation(tx, caller, scope_workspace, operation_key, op_ref, "work_settle", request_digest, work.work_ref, receipt, now)
    end)
end

return M

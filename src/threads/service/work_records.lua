-- MIT. Work-operation identity, receipts and record primitives.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local uuid = require("uuid")
local system = require("system")
local access = require("access")
local journal = require("journal")
local transaction = require("transaction")
local thread_owner = require("thread_owner")
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
local MAX_KEY_BYTES = 128
local MAX_REF_BYTES = 256
local MAX_VALUE_BYTES = 65536
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
    local payload_json, payload_error = encode({kind = kind, session_ref = session.session_ref, subject = subject, revision = revision, operation = operation_ref, data = data}, record_bounds.MAX_RECORD_BYTES - 1024)
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

M.MAX_KEY_BYTES = MAX_KEY_BYTES
M.MAX_REF_BYTES = MAX_REF_BYTES
M.MAX_VALUE_BYTES = MAX_VALUE_BYTES
M.failure = failure
M.object = object
M.has_only = has_only
M.text = text
M.key = key
M.ref = ref
M.integer = integer
M.now_ms = now_ms
M.encode = encode
M.budget_json = budget_json
M.digest = digest
M.request_identity = request_identity
M.allocate_id = allocate_id
M.node_id = node_id
M.qualified = qualified
M.authenticated = authenticated
M.target_workspace = target_workspace
M.mutation_workspace = mutation_workspace
M.operation_replay = operation_replay
M.operation_reference = operation_reference
M.save_operation = save_operation
M.append_event = append_event
M.node_and_operation = node_and_operation
M.operation_context = operation_context
M.finish_operation = finish_operation
M.missing_request = missing_request
M.decode_json = decode_json
M.current_epoch = current_epoch
return M

-- MIT. The approval owner: durable requests bound to an exact proposal
-- digest under a host-selected approver policy, a thread binding authorized
-- when the request is made, decisions committed by compare-and-set together
-- with their thread projection outbox row, expiry enforced by the owner, and
-- consumption bound by the effect owner to one effect identity under the
-- authority incarnation it observed.
local sql = require("sql")
local funcs = require("funcs")
local hash = require("hash")
local uuid = require("uuid")
local json = require("json")
local security = require("security")
local system = require("system")
local process = require("process")
local events = require("events")
local logger = require("logger")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local node_database = require("node_database")
local transaction = require("transaction")
local resources = require("resources")
local clock = require("clock")
local store = require("store")
local approval_outbox = require("outbox")
local runtime_lease = require("runtime_lease")
local windows = require("windows")
local lifecycle = require("lifecycle")
local dispatch = require("dispatch")
local M = {}
M.LABEL = "approval"
M.REQUEST = "bee.approvals.request"
M.DECIDE = "bee.approvals.decide"
M.MANAGE = "bee.approvals.manage"
M.OWN = "bee.approvals.own"
M.CONSUME = "bee.approvals.consume"
M.WORKER_NAME = "bee.approvals.outbox"
M.AUTHORITY_NAME = "bee.approvals.authority"
M.THREAD_GET = "bee.threads.binding:get"
M.THREAD_READ = "bee.threads.binding:read_after"
M.BINDING_PAGES = 4
M.TOPIC_WAKE = "bee.approvals.wake"
M.ATTENTION = "bee.attention"
M.DEFAULT_TTL_MS = 600000
M.MAX_PENDING = 32
M.MAX_INBOX = 64
M.MAX_LIST = 64
M.MAX_BATCH = 16
M.MAX_PROPOSAL_BYTES = 8192
M.MAX_SCHEMA_BYTES = 4096
M.EXPIRE_BOUND = 64
M.RETENTION_MS = 604800000
M.REQUEST_KINDS = {"permission", "question"}
M.DECISIONS = {"allow_once", "allow_grant", "deny", "answer", "approved", "denied"}
M.PROPOSAL_KINDS = {"operation", "attempt"}
M.STATES = {"pending", "decided", "expired", "withdrawn", "superseded", "invalidated"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown, replayed: boolean}
type Result = transaction.Result
type Object = {[string]: unknown}
type RequestKind = "permission" | "question"
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn" | "superseded" | "invalidated"
type Decision = "approved" | "denied"
type Row = {contract_version: integer, contract: Object, reviewed_digest: string, effect_admission_ms: integer?, effect: Object, lifecycle_records: Object, window_grant: windows.Grant?, allowed_by_grant: string?, window_max_ttl_ms: integer, reallow: boolean,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, requester_key: string, request_digest: string, request_kind: RequestKind,
    policy: string, proposal_json: string, proposal: Object, proposal_digest: string,
    prompt_json: string, prompt: Object, response_schema_json: string, response_schema: Object,
    thread_id: string?, binding_json: string?, binding: Object?, revision: integer,
    state: ApprovalState, decision: Decision?, decider_id: string?, decided_at: string?,
    response_json: string?, response: unknown, validated_incarnation: integer?, validated_by: string?,
    validated_at: string?, consumer_id: string?, consumed_effect: string?, consumed_at: string?,
    expires_ms: integer, expires_at: string, created_at: string, updated_at: string?,
    effect_completed_at: string?, effect_result_json: string?, effect_result: unknown,
}
type ApprovalView = {request_digest: string, contract_version: integer, contract: Object, reviewed_digest: string, effect_admission_ms: integer?, effect: Object, lifecycle_records: Object, window_grant: windows.Grant?, allowed_by_grant: string?, window_max_ttl_ms: integer, reallow: boolean, requesting_session: string?,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, request_kind: RequestKind, policy: string, proposal: Object,
    proposal_digest: string, prompt: Object, response_schema: Object, thread_id: string?,
    binding: Object?, revision: integer, state: ApprovalState, decision: Decision?, decider_id: string?,
    decided_at: string?, response: unknown, validated_incarnation: integer?, validated_by: string?,
    validated_at: string?, consumer_id: string?, consumed_effect: string?, consumed_at: string?,
    effect_completed_at: string?, effect_result: unknown, expires_at: string, created_at: string,
    updated_at: string?,
}
type Operation = (sql.Transaction, string, Object, integer, Object?) -> Result
type Preparation = (funcs.Executor, string, Object) -> (Object?, Result?)
local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function refusal(code: string, message: string, value: unknown): Result
    return transaction.refusal(code, message, value)
end
local function storage(what: string): Result
    return failure("STORAGE", what)
end
local function success(value: unknown, replayed: boolean): Result
    return transaction.success(value, replayed)
end
local now_ms = clock.milliseconds
local stamp = clock.stamp
local function node(): (string?, string?)
    local id, err = system.node.id()
    local valid = bounds.id(id)
    if err or not valid then return nil, tostring(err or "native node identity is unavailable") end
    return valid, nil
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function request_kind(value: unknown): RequestKind?
    if value == "permission" then return "permission" end
    if value == "question" then return "question" end
    return nil
end
local function approval_state(value: unknown): ApprovalState?
    if value == "pending" then return "pending" end
    if value == "decided" then return "decided" end
    if value == "expired" then return "expired" end
    if value == "withdrawn" then return "withdrawn" end
    if value == "superseded" then return "superseded" end
    if value == "invalidated" then return "invalidated" end
    return nil
end
local function advance_incarnation(value: unknown): (integer?, string?)
    if type(value) ~= "number" then return nil, "authority incarnation is corrupt" end
    local current: integer? = bounds.count(value)
    if current == nil then return nil, "authority incarnation is corrupt" end
    if current == 0 then return nil, "authority incarnation is corrupt" end
    local advanced = bounds.count(value + 1)
    if advanced == nil then return nil, "authority incarnation is corrupt" end
    return advanced, nil
end
local decode_row: (unknown, sql.Transaction) -> (Row?, string?)
local function digest_of(value: unknown, maximum_bytes: integer?): (string?, string?, string?)
    local encoded, encode_error = canonical.encode(value, maximum_bytes)
    if not encoded then return nil, nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, nil, "digest failed" end
    return sum, encoded, nil
end
local function legacy_replay(object: Object, row: Row, contract: Object): boolean
    if row.contract_version ~= 1 then return false end
    if canonical.encode(contract.subject) ~= canonical.encode(row.contract.subject) then return false end
    local scope, previous_scope = bounds.object(contract.scope), bounds.object(row.contract.scope)
    if not scope or not previous_scope or scope.type ~= previous_scope.type
        or canonical.encode(scope.parameters) ~= canonical.encode(previous_scope.parameters) then return false end
    local evidence = bounds.array(contract.evidence, 64)
    if not evidence or #evidence ~= 0 then return false end
    if object.effect_admission_ms ~= nil and object.effect_admission_ms ~= row.effect_admission_ms then return false end
    local continuation = bounds.object(contract.continuation)
    if continuation and continuation.destination ~= row.effect.destination then return false end
    local fields: {[string]: boolean} = {contract_version = true, subject = true, origin = true, scope = true,
        evidence = true, presentation = true, continuation = true, effect_admission_ms = true}
    local original: Object = {}
    for name, value in pairs(object) do
        if not fields[name] then original[name] = value end
    end
    local digest = digest_of(original, M.MAX_PROPOSAL_BYTES + M.MAX_SCHEMA_BYTES + 16384)
    return digest == row.request_digest
end
local function response_schema_bytes(schema: Object): (string?, string?)
    if next(schema) == nil then return "{}", nil end
    return canonical.encode(schema, M.MAX_SCHEMA_BYTES)
end
function M.open(): (sql.DB?, string?)
    return node_database.open()
end
local function actor_id(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function wake_worker(name: string)
    local pid, err = process.registry.lookup(name)
    if err or not pid then return end
    process.send(tostring(pid), M.TOPIC_WAKE, {version = 1})
end
local function wake(db: sql.DB)
    wake_worker(M.WORKER_NAME)
    local _, err = dispatch.deliver(db, nil)
    if err then logger:warn("Approval effect dispatch failed", {cause = err}) end
end
function M.reply(result: Result): Reply
    if result.ok then return {ok = true, error = nil, value = result.value, replayed = result.replayed} end
    return {ok = false, error = {code = result.code or "INTERNAL", message = result.message or "approval operation failed"}, value = result.value, replayed = false}
end
local operations: {[string]: Operation} = {}
local preparations: {[string]: Preparation} = {}
local mutating: {[string]: boolean} = {request = true, decide = true, decide_batch = true, withdraw = true, consume = true, revalidate = true,
    grant_window = true, runtime_lease = true, reconcile = true, effect = true, events = true, end_request = true, grant = true}
-- execute: one named operation for an actor over an explicit store. A
-- preparation runs first, outside the transaction, for checks that call
-- other authorities through the executor; the operation then runs inside
-- one transaction and the caller's scope answers every authority check.
function M.execute(db: sql.DB, actor: string, name: string, request: unknown, now: integer?, executor: funcs.Executor?): Result
    local operation = operations[name]
    if not operation then return failure("INVALID_ARGUMENT", "unknown operation " .. name) end
    local object = bounds.object(request == nil and {} or request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local prepared: Object? = nil
    local preparation = preparations[name]
    if preparation then
        local outcome, refused = preparation(executor or funcs.new(), actor, object)
        if refused then return refused end
        prepared = outcome
    end
    local at = now or now_ms()
    if mutating[name] then
        return transaction.write(db, M.LABEL, function(tx: sql.Transaction): Result
            return operation(tx, actor, object, at, prepared)
        end)
    end
    return transaction.read(db, M.LABEL, function(tx: sql.Transaction): Result
        return operation(tx, actor, object, at, prepared)
    end)
end
-- A new request waiting for the person is announced on this node, so the
-- desktops working in its workspace open Needs you.
local function announce(value: unknown, db: sql.DB, requested: boolean)
    local view = bounds.object(value)
    local workspace_id = view and bounds.id(view.workspace_id) or nil
    local approval_id = view and bounds.id(view.approval_id) or nil
    if not view or not workspace_id or not approval_id then return end
    requested = requested and view.state == "pending"
    local counted = transaction.read(db, M.LABEL, function(tx: sql.Transaction): Result
        local at = now_ms()
        local count, err = store.attention_count(tx, workspace_id, at)
        if count == nil then return storage(err or "count attention") end
        local target: unknown = nil
        if not requested and count > 0 then
            local found, target_error = store.attention_target(tx, workspace_id, at)
            if not found then return storage(target_error or "pending attention target is missing") end
            target = found
        end
        return success({count = count, target = target}, false)
    end)
    local counts = counted.ok and bounds.object(counted.value)
    local count = counts and bounds.count(counts.count)
    if count == nil then logger:warn("Approval count not announced", {approval_id = approval_id}); return end
    local prompt = bounds.object(view.prompt)
    local target = counts and bounds.object(counts.target)
    if target then
        approval_id = bounds.id(target.approval_id)
        prompt = type(target.prompt_json) == "string" and bounds.object(json.decode(target.prompt_json)) or nil
        if not approval_id or not prompt then logger:warn("Approval target not announced"); return end
    end
    local title = prompt and bounds.line(prompt.text, 160) or nil
    if not title and prompt and type(prompt.text) == "string" then title = prompt.text:gsub("%c", " "):sub(1, 160) end
    local sent, send_error = events.send(M.ATTENTION, requested and "approval.requested" or "approval.changed", workspace_id,
        {approval_id = approval_id, title = title or "Review request", count = count})
    if not sent then logger:warn("Approval not announced", {approval_id = approval_id, error = tostring(send_error)}) end
end
-- Every method authenticates the caller, opens the linked owner store and
-- executes; a committed mutation wakes the outbox worker.
local function run(request: unknown, name: string): Reply
    local actor = actor_id()
    if not actor then return M.reply(failure("UNAUTHENTICATED", "no actor")) end
    local db, open_error = M.open()
    if not db then return M.reply(storage(open_error or "open approval store")) end
    local result = M.execute(db, actor, name, request, nil, nil)
    if mutating[name] and result.ok and not result.replayed then
        wake(db)
        local announced: unknown = result.value
        local envelope = bounds.object(announced)
        if name == "withdraw" then announced = envelope and envelope.request
        elseif name == "decide_batch" then
            local decisions = envelope and bounds.array(envelope.decisions, M.MAX_BATCH)
            announced = decisions and decisions[1]
        end
        announce(announced, db, name == "request")
    end
    db:release()
    return M.reply(result)
end
function M.view(row: Row): ApprovalView
    return {request_digest = row.request_digest, lifecycle_records = row.lifecycle_records, contract_version = row.contract_version, contract = row.contract, reviewed_digest = row.reviewed_digest, effect_admission_ms = row.effect_admission_ms, effect = row.effect, window_grant = row.window_grant, allowed_by_grant = row.allowed_by_grant, window_max_ttl_ms = row.window_max_ttl_ms, reallow = row.reallow, approval_id = row.approval_id, owner_node = row.owner_node, owner_incarnation = row.owner_incarnation, workspace_id = row.workspace_id,
        requesting_session = row.requester_id:match("^bs:") and row.requester_id or nil,
        requester_id = row.requester_id, request_kind = row.request_kind, policy = row.policy, proposal = row.proposal, proposal_digest = row.proposal_digest,
        prompt = row.prompt, response_schema = row.response_schema, thread_id = row.thread_id, binding = row.binding, revision = row.revision, state = row.state,
        decision = row.decision, decider_id = row.decider_id, decided_at = row.decided_at, response = row.response, validated_incarnation = row.validated_incarnation,
        validated_by = row.validated_by, validated_at = row.validated_at, consumer_id = row.consumer_id, consumed_effect = row.consumed_effect,
        consumed_at = row.consumed_at, effect_completed_at = row.effect_completed_at,
        effect_result = row.effect_result,
        expires_at = row.expires_at, created_at = row.created_at, updated_at = row.updated_at}
end
local function load(tx: sql.Transaction, approval_id: string): (Row?, string?)
    local raw, err = store.request(tx, approval_id)
    if err then return nil, err end
    if raw == nil then return nil, nil end
    return decode_row(raw, tx)
end
-- The authority incarnation is established by the authority process before
-- any request is served; a missing row means no authority on this node.
local function incarnation(tx: sql.Transaction, owner: string): (integer?, Result?)
    local raw, exists, err = store.authority(tx, owner)
    if err then return nil, storage("read authority incarnation") end
    if not exists then return nil, failure("UNAVAILABLE", "approval authority is not established on this node") end
    local value = integer(raw)
    if not value or value < 1 then return nil, storage("authority incarnation is corrupt") end
    return value, nil
end
local function authenticated_definition(actor: string): string?
    local definition: string? = nil
    local current = security.actor()
    if current and current:id() == actor then
        local metadata = current:meta()
        if type(metadata) == "table" then definition = bounds.id(metadata.definition_id) end
    end
    return definition
end
local function eligible(actor: string, row: Row): (boolean, string?)
    local workspace_id = text(row.workspace_id) or ""
    if not security.can(M.DECIDE, workspace_id) then return false, nil end
    local policies, policies_error = resources.policies()
    if not policies then return false, policies_error end
    local policy = policies[text(row.policy) or ""]
    if not policy then return false, nil end
    local definition = authenticated_definition(actor)
    for _, approver in ipairs(policy.approvers) do
        if type(approver) == "string" and approver == actor then return true, nil end
        if type(approver) == "table" and definition and approver.definition_id == definition then return true, nil end
    end
    return false, nil
end
-- The thread projection names the outcome: a decision by its value, a
-- withdrawal as cancelled.
local function thread_state(state: string, decision: string?): string
    if state == "decided" then return decision or "denied" end
    if state == "withdrawn" then return "cancelled" end
    return state
end
-- One outbox row: the durable intent to project one body into the thread
-- under a stable event id. The row commits with the change it describes, so
-- a decision is never recorded without its projection being owed.
local function enqueue(tx: sql.Transaction, event_id: string, approval_id: string, revision: integer, thread_id: string, kind: string,
    body: Object, context_json: string?, now: integer, at: string): string?
    local encoded, encode_error = canonical.encode(body, 16384)
    if not encoded then return "encode projection: " .. tostring(encode_error) end
    return approval_outbox.enqueue(tx, {event_id = event_id, approval_id = approval_id, revision = revision,
        thread_id = thread_id, kind = kind, body_json = encoded, context_json = context_json, next_attempt_ms = now, created_at = at})
end
-- A transition record owes nobody anything: only a message commit creates
-- the recipient obligation the delivery layer carries. So the outcome is
-- also addressed to the requester, who is the thread member that asked.
local function notice_of(row: Row, revision: integer, outcome: string): Object
    local approval_id = text(row.approval_id) or ""
    return {message_id = approval_id .. ":" .. tostring(revision) .. ":notice", message_kind = "notification",
        recipient_ids = {text(row.requester_id) or ""}, content = {text = "Approval " .. approval_id .. " is " .. outcome .. "."}}
end
-- Every change is one revision: the history row, the inbox change and,
-- when the request projects onto a thread, the outbox rows all commit with it.
local function record_change(tx: sql.Transaction, row: Row, revision: integer, state: string, decision: string?, actor: string, reason: string, now: integer, body: Object?): string?
    local approval_id, workspace_id = text(row.approval_id) or "", text(row.workspace_id) or ""
    local at = stamp(now)
    local history_error = store.insert_history(tx, approval_id, revision, state, decision, actor, reason, at)
    if history_error then return "record approval history" end
    local inbox_error = store.insert_inbox(tx, workspace_id, approval_id, revision, at)
    if inbox_error then return "record inbox change" end
    local lifecycle_error = lifecycle.change(tx, M.view(row), revision, state, decision, actor, reason, at)
    if lifecycle_error then return lifecycle_error end
    local thread_id = text(row.thread_id)
    if thread_id and body then
        local kind = "approval.transition"
        if state == "pending" then kind = "approval.request" end
        local context_json: string? = nil
        local binding = row.binding
        if binding and binding.attempt_id then
            local encoded, encode_error = canonical.encode({action_id = binding.action_id, attempt_id = binding.attempt_id})
            if not encoded then return "encode thread projection context: " .. tostring(encode_error) end
            context_json = encoded
        end
        local event_id = approval_id .. ":" .. tostring(revision)
        local queued = enqueue(tx, event_id, approval_id, revision, thread_id, kind, body, context_json, now, at)
        if queued then return queued end
        -- Every terminal outcome is announced, a denial and an expiry as
        -- much as an approval: what leaves an agent waiting is not the
        -- refusal but the silence. The notice is a side effect of the
        -- decision and never a condition of it, so it rides the same outbox:
        -- a thread that refuses it retries and finally exhausts that row in
        -- view of `deliveries`, while the decision recorded here stands.
        if state ~= "pending" then
            local announced = enqueue(tx, event_id .. ":notice", approval_id, revision, thread_id, "message",
                notice_of(row, revision, thread_state(state, decision)), context_json, now, at)
            if announced then return announced end
        end
    end
    return nil
end
local function transition_body(row: Row, state: string, decision: string?, decider: string?, response: unknown, reason: string): Object
    return {approval_id = row.approval_id, expected_revision = row.revision, state = thread_state(state, decision), decider_id = decider, response = response, reason = reason}
end
-- Moves one pending request to a terminal state at the next revision.
local function settle(tx: sql.Transaction, row: Row, state: string, decision: string?, decider: string?, response: unknown, actor: string, reason: string, now: integer): (Row?, string?)
    local approval_id = text(row.approval_id) or ""
    local revision = row.revision + 1
    local body = transition_body(row, state, decision, decider, response, reason)
    local change_error = record_change(tx, row, revision, state, decision, actor, reason, now, body)
    if change_error then return nil, change_error end
    local response_json: string? = nil
    if response ~= nil then
        local encoded, encode_error = canonical.encode(response)
        if not encoded then return nil, "encode approval response: " .. tostring(encode_error) end
        response_json = encoded
    end
    local decided_at: string? = nil
    if state == "decided" then decided_at = stamp(now) end
    local update_error = store.transition(tx, approval_id, revision, state, decision, decider, decided_at, response_json, stamp(now))
    if update_error then return nil, "settle approval request" end
    if state == "decided" then
        local _, response_error = tx:execute("UPDATE bee_approval_decisions SET response_json = ? WHERE approval_id = ? AND revision = ?", {response_json, approval_id, revision})
        if response_error then return nil, "record decision response" end
    end
    return load(tx, approval_id)
end
-- Returns the current row and whether this call enforced the deadline.
local function expire_if_due(tx: sql.Transaction, row: Row, now: integer): (Row?, string?, boolean)
    if row.state ~= "pending" or row.expires_ms > now then return row, nil, false end
    local settled, err = settle(tx, row, "expired", nil, nil, nil, row.owner_node, "deadline passed at the owner", now)
    return settled, err, settled ~= nil
end
local function proposal_of(value: unknown): (Object?, string?, string?, string?)
    local object = bounds.object(value)
    if not object then return nil, nil, nil, "proposal must be an object" end
    local unknown_field = bounds.fields(object, {"kind", "ref", "revision", "action_id", "input_digest", "payload"})
    if unknown_field then return nil, nil, nil, "proposal: " .. unknown_field end
    local kind = bounds.member(object.kind, M.PROPOSAL_KINDS)
    if not kind then return nil, nil, nil, "proposal kind must be operation or attempt" end
    local ref, revision = bounds.id(object.ref), bounds.id(object.revision)
    if not ref then return nil, nil, nil, "proposal ref is not an identifier" end
    if not revision then return nil, nil, nil, "proposal revision is not an identifier" end
    local action_id, action_valid = values.optional_id(object, "action_id")
    if not action_valid then return nil, nil, nil, "proposal action_id is not an identifier" end
    if action_id and kind ~= "attempt" then return nil, nil, nil, "proposal action_id belongs to an attempt proposal" end
    local input_digest: string? = nil
    if object.input_digest ~= nil then
        input_digest = text(object.input_digest)
        if not input_digest or not input_digest:match("^%x+$") or #input_digest ~= 64 then return nil, nil, nil, "proposal input_digest must be a sha256 hex digest" end
    end
    local payload = bounds.object(object.payload == nil and {} or object.payload)
    if not payload then return nil, nil, nil, "proposal payload must be an object" end
    local proposal: Object = {kind = kind, ref = ref, revision = revision, action_id = action_id, input_digest = input_digest, payload = payload}
    local digest, encoded, digest_error = digest_of(proposal, M.MAX_PROPOSAL_BYTES)
    if not digest or not encoded then return nil, nil, nil, "proposal: " .. tostring(digest_error) end
    return proposal, digest, encoded, nil
end
local function optional_text(object: Object, key: string): (string?, boolean)
    local value = object[key]
    if value == nil then return nil, true end
    if type(value) ~= "string" then return nil, false end
    return value, true
end
local function stored_json(object: Object, key: string, optional: boolean, object_only: boolean): (unknown, string?)
    local raw = object[key]
    if raw == nil and optional then return nil, nil end
    if type(raw) ~= "string" then return nil, key .. " is not stored as JSON text" end
    local value, decode_error = json.decode(raw)
    if value == nil then return nil, key .. " is corrupt: " .. tostring(decode_error or "invalid JSON") end
    if object_only and not bounds.object(value) then return nil, key .. " is not a JSON object" end
    local encoded, encode_error = canonical.encode(value)
    if not encoded or encoded ~= raw then return nil, key .. " is not canonical JSON: " .. tostring(encode_error or "encoding differs") end
    return value, nil
end
decode_row = function(raw: unknown, tx: sql.Transaction): (Row?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "approval row is not an object" end
    local approval_id = bounds.id(value.approval_id)
    local owner_node = bounds.id(value.owner_node)
    local owner_incarnation = bounds.integer(value.owner_incarnation)
    local workspace_id = bounds.id(value.workspace_id)
    local requester_id = bounds.id(value.requester_id)
    local requester_key = bounds.id(value.requester_key)
    local request_digest = value.request_digest
    local request_kind = request_kind(value.request_kind)
    local policy = bounds.id(value.policy)
    local proposal_digest = value.proposal_digest
    local revision = bounds.integer(value.revision)
    local state = approval_state(value.state)
    local raw_decision = value.decision
    local decision: Decision? = nil
    if raw_decision == "approved" or raw_decision == "denied" then decision = raw_decision end
    local expires_ms = bounds.integer(value.expires_ms)
    local expires_at = bounds.timestamp(value.expires_at)
    local created_at = bounds.timestamp(value.created_at)
    local updated_at = bounds.timestamp(value.updated_at)
    if expires_at == nil then return nil, "approval row has invalid expiry timestamp" end
    if expires_ms == nil then return nil, "approval row has invalid expiry deadline" end
    if revision == nil then return nil, "approval row has invalid revision" end
    if revision < 1 then return nil, "approval row has invalid revision" end
    if request_kind == nil then return nil, "approval row has invalid request kind" end
    if state == nil then return nil, "approval row has invalid state" end
    if not approval_id or not owner_node or not owner_incarnation or owner_incarnation < 1 or not workspace_id
        or not requester_id or not requester_key or type(request_digest) ~= "string" or #request_digest ~= 64
        or not request_digest:match("^%x+$") or not policy or type(proposal_digest) ~= "string"
        or #proposal_digest ~= 64 or not proposal_digest:match("^%x+$")
        or (raw_decision ~= nil and not decision) or (state == "decided") ~= (decision ~= nil)
        or not created_at or not updated_at then
        return nil, "approval row has invalid required fields"
    end
    local proposal_value, proposal_json_error = stored_json(value, "proposal_json", false, true)
    if proposal_json_error then return nil, proposal_json_error end
    local proposal, proposal_digest_check, proposal_json, proposal_error = proposal_of(proposal_value)
    if not proposal or not proposal_json or proposal_json ~= value.proposal_json or proposal_digest_check ~= proposal_digest then
        return nil, "approval proposal is corrupt: " .. tostring(proposal_error or "digest or canonical form differs")
    end
    local stored_proposal_json: string = proposal_json
    local prompt_value, prompt_error = stored_json(value, "prompt_json", false, true)
    if prompt_error then return nil, prompt_error end
    local prompt, content_error = values.content(prompt_value)
    if not prompt then return nil, "approval prompt is corrupt: " .. tostring(content_error) end
    local prompt_json = canonical.encode(prompt)
    if not prompt_json or prompt_json ~= value.prompt_json then return nil, "approval prompt is not canonical" end
    local schema_value, schema_error = stored_json(value, "response_schema_json", false, true)
    if schema_error then return nil, schema_error end
    local response_schema_json = value.response_schema_json
    if type(response_schema_json) ~= "string" then return nil, "approval response schema is corrupt" end
    local response_schema = bounds.object(schema_value)
    if not response_schema then return nil, "approval response schema is corrupt" end
    local thread_id, thread_valid = optional_text(value, "thread_id")
    if thread_id and not bounds.id(thread_id) then thread_valid = false end
    local binding_json, binding_text_valid = optional_text(value, "binding_json")
    if not binding_text_valid then return nil, "approval binding is corrupt" end
    local binding_value: unknown = nil
    local binding: Object? = nil
    if value.binding_json ~= nil then
        binding_value, schema_error = stored_json(value, "binding_json", true, true)
        if schema_error then return nil, schema_error end
        binding = bounds.object(binding_value)
        if not binding then return nil, "approval binding is corrupt" end
    end
    if not thread_valid or (thread_id == nil) ~= (binding == nil) then return nil, "approval thread binding is corrupt" end
    local decider_id, decider_valid = optional_text(value, "decider_id")
    if decider_id and not bounds.id(decider_id) then decider_valid = false end
    local decided_at: string? = nil
    if value.decided_at ~= nil then decided_at = bounds.timestamp(value.decided_at) end
    if not decider_valid or (value.decided_at ~= nil and not decided_at)
        or (state == "decided" and (not decider_id or not decided_at))
        or (state ~= "decided" and (decider_id ~= nil or decided_at ~= nil)) then
        return nil, "approval decision metadata is corrupt"
    end
    local response_json: string? = nil
    if value.response_json ~= nil then
        if type(value.response_json) ~= "string" then return nil, "approval response is not stored as JSON text" end
        response_json = value.response_json
    end
    local response, response_json_error = stored_json(value, "response_json", true, false)
    if response_json_error then return nil, response_json_error end
    local validated_incarnation: integer? = nil
    if value.validated_incarnation ~= nil then
        validated_incarnation = bounds.integer(value.validated_incarnation)
        if not validated_incarnation then return nil, "approval effect metadata is corrupt" end
    end
    local validated_by, validated_by_valid = optional_text(value, "validated_by")
    if validated_by and not bounds.id(validated_by) then validated_by_valid = false end
    local validated_at: string? = nil
    if value.validated_at ~= nil then validated_at = bounds.timestamp(value.validated_at) end
    local consumer_id, consumer_valid = optional_text(value, "consumer_id")
    if consumer_id and not bounds.id(consumer_id) then consumer_valid = false end
    local consumed_effect, effect_valid = optional_text(value, "consumed_effect")
    if consumed_effect and not bounds.id(consumed_effect) then effect_valid = false end
    local consumed_at: string? = nil
    if value.consumed_at ~= nil then consumed_at = bounds.timestamp(value.consumed_at) end
    local effect_completed_at: string? = nil
    if value.effect_completed_at ~= nil then effect_completed_at = bounds.timestamp(value.effect_completed_at) end
    local effect_result_json: string? = nil
    local effect_result: unknown = nil
    if value.effect_result_json ~= nil then
        if type(value.effect_result_json) ~= "string" then return nil, "approval effect result is corrupt" end
        effect_result_json = value.effect_result_json
        effect_result, schema_error = stored_json(value, "effect_result_json", true, true)
        if schema_error then return nil, schema_error end
    end
    local validated_present = validated_incarnation ~= nil or validated_by ~= nil or validated_at ~= nil
    if (value.validated_at ~= nil and not validated_at) or (value.effect_completed_at ~= nil and not effect_completed_at)
        or (validated_incarnation ~= nil and (validated_incarnation < 1 or not validated_by or not validated_at))
        or (validated_present and (not validated_incarnation or not validated_by or not validated_at))
        or not validated_by_valid or not consumer_valid or not effect_valid
        or ((consumer_id ~= nil or consumed_effect ~= nil or consumed_at ~= nil)
            and (not consumer_id or not consumed_effect or not consumed_at))
        or ((effect_completed_at ~= nil) ~= (effect_result ~= nil)) then
        return nil, "approval effect metadata is corrupt"
    end
    local scope_digest, scope_error = windows.scope_digest(proposal)
    if not scope_digest then return nil, scope_error end
    local grant: windows.Grant? = nil
    local grant_id = value.window_grant_id == nil and nil or bounds.id(value.window_grant_id)
    local automatic = value.allowed_by_grant == nil and nil or bounds.id(value.allowed_by_grant)
    if (value.window_grant_id ~= nil and not grant_id) or (value.allowed_by_grant ~= nil and (not automatic or automatic ~= grant_id)) then return nil, "approval window reference is corrupt" end
    if grant_id then
        local raw_grant, read_error = store.window(tx, grant_id)
        if read_error then return nil, read_error end
        local grant_error: string? = nil
        grant, grant_error = windows.decode(raw_grant)
        if not grant then return nil, grant_error end
        if grant.owner_node ~= owner_node or grant.workspace_id ~= workspace_id or grant.requester_id ~= requester_id
            or grant.policy ~= policy or grant.scope_digest ~= scope_digest or state ~= "decided" or decision ~= "approved" then
            return nil, "approval window does not cover this request"
        end
    end
    local policies, policies_error = resources.policies()
    if not policies then return nil, policies_error end
    local configured = policies[policy]
    local maximum = request_kind == "permission" and configured and configured.max_ttl_ms or 0
    local previous, previous_error = store.matching_windows(tx, owner_node, workspace_id, requester_id, policy, scope_digest)
    if previous_error or not previous then return nil, previous_error end
    local prior = #previous > 0
    local contract_version = bounds.integer(value.contract_version)
    local contract = type(value.contract_json) == "string" and bounds.object(json.decode(value.contract_json)) or nil
    local reviewed_digest = bounds.text(value.reviewed_digest, 64)
    local effect_admission_ms = value.effect_admission_ms == nil and nil or bounds.integer(value.effect_admission_ms)
    local effect, effect_error = lifecycle.read(tx, approval_id)
    if not contract_version or (contract_version ~= 1 and contract_version ~= lifecycle.VERSION) or not contract or not reviewed_digest or #reviewed_digest ~= 64 or not effect
        or (value.effect_admission_ms ~= nil and not effect_admission_ms) then return nil, effect_error or "approval lifecycle is corrupt" end
    if contract_version == lifecycle.VERSION then
        local encoded = canonical.encode(contract, 32768)
        local measured = encoded and hash.sha256(encoded) or nil
        if encoded ~= value.contract_json or measured ~= reviewed_digest then return nil, "approval review digest is corrupt" end
    end
    if contract.reviewed_required == true then maximum = 0 end
    local records, records_error = lifecycle.records(tx, approval_id)
    if not records then return nil, records_error end
    local row: Row = {lifecycle_records = records, contract_version = contract_version, contract = contract, reviewed_digest = reviewed_digest,
        effect_admission_ms = effect_admission_ms, effect = effect, window_grant = grant, allowed_by_grant = automatic, window_max_ttl_ms = maximum, reallow = state == "pending" and prior, approval_id = approval_id, owner_node = owner_node, owner_incarnation = owner_incarnation,
        workspace_id = workspace_id, requester_id = requester_id, requester_key = requester_key, request_digest = request_digest,
        request_kind = request_kind, policy = policy, proposal_json = stored_proposal_json, proposal = proposal,
        proposal_digest = proposal_digest, prompt_json = prompt_json, prompt = prompt,
        response_schema_json = response_schema_json, response_schema = response_schema,
        thread_id = thread_id, binding_json = binding_json, binding = binding, revision = revision, state = state,
        decision = decision, decider_id = decider_id, decided_at = decided_at,
        response_json = response_json, response = response, validated_incarnation = validated_incarnation,
        validated_by = validated_by, validated_at = validated_at, consumer_id = consumer_id, consumed_effect = consumed_effect,
        consumed_at = consumed_at, expires_ms = expires_ms, expires_at = expires_at, created_at = created_at,
        updated_at = updated_at, effect_completed_at = effect_completed_at, effect_result_json = effect_result_json,
        effect_result = effect_result}
    return row, nil
end
local function thread_reply(executor: funcs.Executor, target: string, request: Object): (Object?, Result?)
    local reply, call_error = executor:call(target, request)
    if call_error then return nil, failure("UNAVAILABLE", "thread authority call failed: " .. tostring(call_error)) end
    local typed = bounds.object(reply)
    if not typed or type(typed.ok) ~= "boolean" then return nil, failure("INTERNAL", "thread authority returned a malformed reply") end
    if typed.ok == false then
        local fault = bounds.object(typed.error)
        if not fault then return nil, failure("INTERNAL", "thread authority returned a malformed refusal") end
        local code = bounds.id(fault.code)
        local message = bounds.text(fault.message)
        if not code or not message then return nil, failure("INTERNAL", "thread authority returned a malformed refusal") end
        return nil, failure(code, "thread authority: " .. message)
    end
    local value = bounds.object(typed.value)
    if not value then return nil, failure("INTERNAL", "thread authority returned a malformed success value") end
    return value, nil
end
-- The thread binding is authorized when the request is made: the requester
-- is an active owner or participant of the thread, and an attempt proposal
-- names an attempt the thread prepared under the named action. The binding
-- is persisted so delivery never depends on later membership.
local function prepare_request(executor: funcs.Executor, actor: string, object: Object): (Object?, Result?)
    if object.thread_id == nil then return nil, nil end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return nil, failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    local proposal = bounds.object(object.proposal)
    if not proposal then return nil, failure("INVALID_ARGUMENT", "proposal must be an object") end
    local summary, denied = thread_reply(executor, M.THREAD_GET, {thread_id = thread_id})
    if not summary then return nil, denied end
    local membership = bounds.object(summary.membership)
    if not membership then return nil, failure("INTERNAL", "thread authority returned malformed membership data") end
    local role = membership.role
    local membership_revision = bounds.count(membership.revision)
    if type(membership.active) ~= "boolean" or not membership_revision then
        return nil, failure("INTERNAL", "thread authority returned malformed membership data")
    end
    if membership.active ~= true or (role ~= "owner" and role ~= "participant") then
        return nil, failure("DENIED", "requester is not an active owner or participant of the thread")
    end
    local binding: Object = {thread_id = thread_id, role = role, membership_revision = membership_revision, checked_at = stamp(now_ms())}
    if proposal.kind == "attempt" then
        local action_id, attempt_id = bounds.id(proposal.action_id), bounds.id(proposal.ref)
        if not action_id then return nil, failure("INVALID_ARGUMENT", "an attempt proposal bound to a thread names its action_id") end
        if not attempt_id then return nil, failure("INVALID_ARGUMENT", "proposal ref is not an identifier") end
        local cursor = 0
        local found: Object? = nil
        for _ = 1, M.BINDING_PAGES do
            local page, refused = thread_reply(executor, M.THREAD_READ, {thread_id = thread_id, cursor = cursor, filter = {kinds = {"attempt.prepared", "attempt.started"}, action_id = action_id}})
            if not page then return nil, refused end
            local records = type(page.records) == "table" and (page.records) or nil
            if not records then return nil, failure("INTERNAL", "thread authority returned malformed records") end
            for _, raw in ipairs(records) do
                local record = bounds.object(raw)
                if not record then return nil, failure("INTERNAL", "thread authority returned a malformed record") end
                if record.attempt_id == attempt_id then found = record end
            end
            local next_cursor = integer(page.scanned_through)
            if not next_cursor then return nil, failure("INTERNAL", "thread authority returned a malformed cursor") end
            if found or next_cursor <= cursor then break end
            cursor = next_cursor
        end
        if not found then return nil, failure("INVALID_ARGUMENT", "attempt " .. attempt_id .. " is not prepared under action " .. action_id .. " in the thread") end
        binding.action_id, binding.attempt_id, binding.record_id = action_id, attempt_id, found.record_id
    end
    return binding, nil
end
-- request: the authenticated operation owner asks for a decision on one
-- exact proposal under a host policy; the same key replays, a different
-- request under it conflicts.
local function op_request(tx: sql.Transaction, actor: string, object: Object, now: integer, binding: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "idempotency_key", "request_kind", "policy", "proposal", "prompt", "response_schema", "thread_id", "ttl_ms", "contract_version", "subject", "origin", "scope", "evidence", "presentation", "continuation", "effect_admission_ms"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local workspace_id, key = bounds.id(object.workspace_id), bounds.id(object.idempotency_key)
    if not workspace_id then return failure("INVALID_ARGUMENT", "workspace_id is not an identifier") end
    if not key then return failure("INVALID_ARGUMENT", "idempotency_key is not an identifier") end
    local request_kind = bounds.member(object.request_kind, M.REQUEST_KINDS)
    if not request_kind then return failure("INVALID_ARGUMENT", "request_kind must be permission or question") end
    local policy_name = bounds.id(object.policy)
    if not policy_name then return failure("INVALID_ARGUMENT", "policy is not an identifier") end
    local proposal, proposal_digest, proposal_json, proposal_error = proposal_of(object.proposal)
    if not proposal or not proposal_digest or not proposal_json then return failure("INVALID_ARGUMENT", proposal_error or "proposal") end
    if proposal.ref == runtime_lease.REF then
        local ceiling, err = runtime_lease.decode(proposal.payload)
        if not ceiling or ceiling.subject ~= actor or ceiling.workspace_id ~= workspace_id or ceiling.expires_ms <= now
            or ceiling.expires_ms > now + 2592000000 then return failure("INVALID_ARGUMENT", err or "runtime lease must belong to its requester and expire within 30 days") end
    end
    local prompt, prompt_error = values.content(object.prompt)
    if not prompt then return failure("INVALID_ARGUMENT", "prompt: " .. tostring(prompt_error)) end
    local schema = bounds.object(object.response_schema == nil and {} or object.response_schema)
    if not schema then return failure("INVALID_ARGUMENT", "response_schema must be an object") end
    local schema_json, schema_error = response_schema_bytes(schema)
    if not schema_json then return failure("INVALID_ARGUMENT", "response_schema: " .. tostring(schema_error)) end
    local thread_id, thread_valid = values.optional_id(object, "thread_id")
    if not thread_valid then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    if not security.can(M.REQUEST, workspace_id) then return failure("DENIED", "caller may not request approvals in workspace " .. workspace_id) end
    local policies, policies_error = resources.policies()
    if not policies then return storage(policies_error or "approver policies") end
    local policy = policies[policy_name]
    if not policy then return failure("NOT_FOUND", "approver policy " .. policy_name .. " is not configured on this host") end
    local ttl = math.min(policy.request_ttl_ms or M.DEFAULT_TTL_MS, policy.max_ttl_ms)
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 then return failure("INVALID_ARGUMENT", "ttl_ms must be a positive integer") end
        if declared > policy.max_ttl_ms then return failure("FORBIDDEN", "ttl_ms exceeds the policy ceiling of " .. tostring(policy.max_ttl_ms)) end
        ttl = declared
    end
    local contract, contract_error = lifecycle.prepare(actor, object, proposal, proposal_digest, now + policy.max_ttl_ms, policy)
    if not contract then return failure("INVALID_ARGUMENT", contract_error or "approval contract") end
    local request_digest, _, digest_error = digest_of(object, M.MAX_PROPOSAL_BYTES + M.MAX_SCHEMA_BYTES + 16384)
    if not request_digest then return failure("INVALID_ARGUMENT", "request: " .. tostring(digest_error)) end
    local existing_rows, existing_error = store.request_by_key(tx, actor, key)
    if existing_error or not existing_rows then return storage("read approval request") end
    if #existing_rows > 0 then
        local existing, decode_error = decode_row(existing_rows[1], tx)
        if not existing then return storage("decode existing approval request: " .. tostring(decode_error)) end
        if existing.request_digest ~= request_digest and not legacy_replay(object, existing, contract.value) then
            return failure("CONFLICT", "idempotency key was used by a different request")
        end
        return success(M.view(existing), true)
    end
    local pending_count_value, pending_error = store.pending_count(tx, actor)
    if pending_error then return storage("count pending requests") end
    local pending_count = integer(pending_count_value)
    if not pending_count or pending_count < 0 then return storage("pending request count is corrupt") end
    if pending_count >= M.MAX_PENDING then return failure("LIMIT_EXCEEDED", "requester has " .. tostring(M.MAX_PENDING) .. " pending requests") end
    local owner, node_error = node()
    if not owner then return failure("UNAVAILABLE", node_error or "native node identity is unavailable") end
    local owner_incarnation, unavailable = incarnation(tx, owner)
    if not owner_incarnation then return unavailable or storage("authority incarnation") end
    local approval_id, id_error = uuid.v7()
    if id_error or not approval_id then return storage("approval id") end
    local prompt_json, prompt_encode_error = canonical.encode(prompt)
    if not prompt_json then return failure("INTERNAL", "encode approval prompt: " .. tostring(prompt_encode_error)) end
    local binding_json: string? = nil
    if binding then
        local encoded, binding_encode_error = canonical.encode(binding)
        if not encoded then return failure("INTERNAL", "encode thread binding: " .. tostring(binding_encode_error)) end
        binding_json = encoded
    end
    local expires = now + ttl
    local at = stamp(now)
    local insert_error = store.insert_request(tx, {approval_id = approval_id, owner_node = owner, owner_incarnation = owner_incarnation,
        workspace_id = workspace_id, requester_id = actor, requester_key = key, request_digest = request_digest,
        request_kind = request_kind, policy = policy_name, proposal_json = proposal_json, proposal_digest = proposal_digest,
        prompt_json = prompt_json, response_schema_json = schema_json, thread_id = thread_id, binding_json = binding_json,
        expires_ms = expires, expires_at = stamp(expires), created_at = at})
    if insert_error then return storage("record approval request") end
    local attach_error = lifecycle.attach(tx, approval_id, contract, at)
    if attach_error then return storage(attach_error) end
    local row, load_error = load(tx, approval_id)
    if not row then return storage(load_error or "read approval request") end
    local body: Object = {approval_id = approval_id, request_kind = request_kind, requester_id = actor, operation_ref = proposal.ref, prompt = prompt,
        response_schema = schema, expires_at = stamp(expires), state = "pending"}
    local change_error = record_change(tx, row, 1, "pending", nil, actor, "requested", now, body)
    if change_error then return storage(change_error) end
    if request_kind == "permission" and contract.value.reviewed_required ~= true then
        local scope_digest, scope_error = windows.scope_digest(proposal)
        if not scope_digest then return storage(scope_error or "measure approval window scope") end
        local grants, grant_error = store.matching_windows(tx, owner, workspace_id, actor, policy_name, scope_digest)
        if grant_error or not grants then return storage(grant_error or "read matching approval windows") end
        for _, raw_grant in ipairs(grants) do
            local grant, decode_error = windows.decode(raw_grant)
            if not grant then return storage(decode_error or "decode approval window") end
            local authorized = false
            for _, approver in ipairs(policy.approvers) do
                if type(approver) == "string" and approver == grant.granted_by then authorized = true end
                if type(approver) == "table" and approver.definition_id == grant.granted_definition then authorized = true end
            end
            if authorized and not grant.revoked_at and grant.until_ms > now and (grant.until_ms - grant.granted_ms <= policy.max_ttl_ms or (policy.allow_permanent and grant.until_ms == windows.PERMANENT_UNTIL_MS)) then
                local attach_error = store.attach_window(tx, row.approval_id, grant.grant_id, true)
                if attach_error then return storage(attach_error) end
                local settled, settle_error = settle(tx, row, "decided", "approved", grant.granted_by, nil, grant.granted_by,
                    "allowed by window grant " .. grant.grant_id, now)
                if not settled then return storage(settle_error or "settle by approval window") end
                return success(M.view(settled), false)
            end
        end
    end
    return success(M.view(row), false)
end
-- decide: an eligible approver settles the pending revision for the exact
-- proposal digest; an identical retry replays, anything else conflicts.
local function op_decide(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "decision", "proposal_digest", "response", "window_ttl_ms", "window_permanent", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 then return failure("INVALID_ARGUMENT", "expected_revision must be a positive integer") end
    local declared_decision = bounds.member(object.decision, M.DECISIONS)
    if not declared_decision then return failure("INVALID_ARGUMENT", "decision kind is invalid") end
    local decision = (declared_decision == "deny" or declared_decision == "denied") and "denied" or "approved"
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return failure("INVALID_ARGUMENT", "proposal_digest is required") end
    local response: unknown = nil
    if object.response ~= nil then
        local content, content_error = values.content(object.response)
        if not content then return failure("INVALID_ARGUMENT", "response: " .. tostring(content_error)) end
        response = content
    end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if declared_decision == "answer" and row.request_kind ~= "question" then return failure("INVALID_ARGUMENT", "answer needs a question") end
    if declared_decision == "allow_once" and row.request_kind ~= "permission" then return failure("INVALID_ARGUMENT", "allow_once needs a permission") end
    if declared_decision == "allow_grant" and object.window_ttl_ms == nil then return failure("INVALID_ARGUMENT", "allow_grant requires reviewed window terms") end
    local may_decide, policy_error = eligible(actor, row)
    if policy_error then return storage(policy_error) end
    if not may_decide then return failure("DENIED", "caller is not an eligible approver for this request") end
    local window_ttl: integer? = nil
    if object.window_permanent ~= nil and type(object.window_permanent) ~= "boolean" then return failure("INVALID_ARGUMENT", "window_permanent must be boolean") end
    if object.window_permanent == true then
        if object.window_ttl_ms ~= nil then return failure("INVALID_ARGUMENT", "choose duration or permanent") end
        local policies, policy_error = resources.policies()
        if not policies then return storage(policy_error or "approver policies") end
        local configured = policies[row.policy]
        if not configured or not configured.allow_permanent then return failure("FORBIDDEN", "policy does not permit permanent windows") end
        if decision ~= "approved" or row.request_kind ~= "permission" or response ~= nil then return failure("INVALID_ARGUMENT", "windows approve permissions without a response") end
        window_ttl = windows.PERMANENT_UNTIL_MS - now
    end
    if object.window_ttl_ms ~= nil then
        window_ttl = bounds.integer(object.window_ttl_ms)
        if not window_ttl or window_ttl < 1 then return failure("INVALID_ARGUMENT", "window_ttl_ms must be a positive integer") end
        if row.contract.reviewed_required == true then return failure("INVALID_ARGUMENT", "approval windows require the exact requester proposal scope") end
        if decision ~= "approved" or row.request_kind ~= "permission" or response ~= nil then return failure("INVALID_ARGUMENT", "windows approve permissions without a response") end
        if window_ttl > row.window_max_ttl_ms then return failure("FORBIDDEN", "window_ttl_ms exceeds the policy ceiling of " .. tostring(row.window_max_ttl_ms)) end
    end
    if row.proposal_digest ~= proposal_digest then return failure("CONFLICT", "proposal digest does not match the recorded proposal", M.view(row)) end
    if object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest then
        return failure("CONFLICT", "reviewed digest does not match the recorded review", M.view(row))
    end
    local evidence = bounds.array(row.contract.evidence, 64)
    if (row.contract.reviewed_required == true or (evidence and #evidence > 0)) and object.reviewed_digest == nil then return failure("INVALID_ARGUMENT", "reviewed_digest is required for evidence-bound decisions") end
    if row.request_kind == "question" and decision == "approved" then
        if response == nil then return failure("INVALID_ARGUMENT", "a question needs a response to be approved") end
        local schema_json, encode_error = response_schema_bytes(row.response_schema)
        if not schema_json then return storage(encode_error or "encode response schema") end
        local valid, schema_error = json.validate(schema_json, response)
        if not valid or schema_error then return failure("INVALID_ARGUMENT", "answer does not match its response schema: " .. tostring(schema_error)) end
    end
    local current, expire_error, expired_now = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state == "decided" then
        local wanted = ""
        if response ~= nil then wanted = canonical.encode(response) or "" end
        local same_response = wanted == (text(current.response_json) or "")
        local same_window = window_ttl == nil and current.window_grant == nil
            or (window_ttl ~= nil and current.window_grant ~= nil and current.allowed_by_grant == nil
                and (current.window_grant.until_ms - current.window_grant.granted_ms == window_ttl
                    or (object.window_permanent == true and current.window_grant.until_ms == windows.PERMANENT_UNTIL_MS)))
        if current.decider_id == actor and current.decision == decision and same_response and same_window then return success(M.view(current), true) end
        return failure("CONFLICT", "request was decided " .. tostring(current.decision) .. " by " .. tostring(current.decider_id), M.view(current))
    end
    if expired_now then return refusal("INVALID_STATE", "request expired at its deadline", M.view(current)) end
    if current.state ~= "pending" then return failure("INVALID_STATE", "request is " .. tostring(current.state), M.view(current)) end
    if current.revision ~= expected then return failure("CONFLICT", "request is at revision " .. tostring(current.revision), M.view(current)) end
    if window_ttl then
        local grant_id = current.approval_id
        local scope_digest, scope_error = windows.scope_digest(current.proposal)
        if not scope_digest then return storage(scope_error or "measure approval window scope") end
        local matches, match_error = store.matching_windows(tx, current.owner_node, current.workspace_id, current.requester_id, current.policy, scope_digest)
        if not matches or match_error then return storage(match_error or "read approval window") end
        local reused = false
        if #matches > 0 then
            local previous, decode_error = windows.decode(matches[1])
            if not previous then return storage(decode_error or "decode approval window") end
            if not previous.revoked_at and previous.granted_by == actor and previous.granted_ms == now and previous.until_ms == now + window_ttl then
                grant_id = previous.grant_id
                reused = true
            end
        end
        if not reused then
            local grant: windows.Grant = {grant_id = grant_id, owner_node = current.owner_node, workspace_id = current.workspace_id,
                requester_id = current.requester_id, policy = current.policy, scope_digest = scope_digest,
                granted_by = actor, granted_definition = authenticated_definition(actor), granted_ms = now, granted_at = stamp(now),
                until_ms = now + window_ttl, until_at = stamp(now + window_ttl), revoked_at = nil}
            local supersede_error = store.supersede_windows(tx, grant)
            if supersede_error then return storage(supersede_error) end
            local grant_error = store.insert_window(tx, grant)
            if grant_error then return storage(grant_error) end
        end
        local attach_error = store.attach_window(tx, current.approval_id, grant_id, false)
        if attach_error then return storage(attach_error) end
    end
    local settled, settle_error = settle(tx, current, "decided", decision, actor, response, actor, "decided " .. decision, now)
    if not settled then return storage(settle_error or "settle decision") end
    return success(M.view(settled), false)
end
-- decide_batch: several pending requests of one requester in one workspace are
-- decided together in a single transaction. Every item carries exactly the
-- fields decide requires; the grouping is read from the stored rows, so a
-- mixed batch is refused before any decision commits and one failing item
-- rolls the whole batch back.
local function op_decide_batch(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"decisions", "window_ttl_ms"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local items = bounds.dense_list(object.decisions, M.MAX_BATCH, "decisions")
    if not items or #items < 1 then return failure("INVALID_ARGUMENT", "decisions must list 1 to " .. tostring(M.MAX_BATCH) .. " requests") end
    local seen: {[string]: boolean} = {}
    local requester: string? = nil
    local workspace: string? = nil
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local approval_id = item and bounds.id(item.approval_id) or nil
        if not item or not approval_id then return failure("INVALID_ARGUMENT", "every decision names an approval_id") end
        if seen[approval_id] then return failure("INVALID_ARGUMENT", "a request appears once per batch") end
        seen[approval_id] = true
        local row, load_error = load(tx, approval_id)
        if load_error then return storage(load_error) end
        if not row then return failure("NOT_FOUND", "approval request does not exist") end
        if requester == nil then requester, workspace = row.requester_id, row.workspace_id end
        if row.requester_id ~= requester or row.workspace_id ~= workspace then
            return failure("INVALID_ARGUMENT", "a batch decides requests of one requester in one workspace")
        end
    end
    local views: {unknown} = {}
    for _, raw in ipairs(items) do
        local decision = bounds.object(raw)
        if not decision then return failure("INVALID_ARGUMENT", "decision must be an object") end
        if object.window_ttl_ms ~= nil then
            if decision.window_ttl_ms ~= nil then return failure("INVALID_ARGUMENT", "a batch has one window choice") end
            local copied: Object = {}
            for key, value in pairs(decision) do copied[key] = value end
            copied.window_ttl_ms = object.window_ttl_ms
            decision = copied
        end
        local settled = op_decide(tx, actor, decision, now, prepared)
        if not settled.ok then
            local fault = bounds.object(raw)
            return failure(settled.code or "INTERNAL", tostring(fault and fault.approval_id) .. ": " .. tostring(settled.message), bounds.object(settled.value))
        end
        views[#views + 1] = settled.value
    end
    return success({decisions = views}, false)
end
-- withdraw: the requester ends its own pending request; a request already
-- settled reports the outcome that actually committed.
local function op_withdraw(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "proposal_digest", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if row.requester_id ~= actor then return failure("DENIED", "only the requester withdraws a request") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 or not bounds.id(object.proposal_digest) then return failure("INVALID_ARGUMENT", "withdraw requires expected_revision and proposal_digest") end
    if object.proposal_digest ~= row.proposal_digest or ((row.contract.reviewed_required == true or object.reviewed_digest ~= nil) and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "withdraw review differs from the request", M.view(row)) end
    local current, expire_error = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state ~= "pending" then return success({withdrawn = false, request = M.view(current)}, current.state == "withdrawn") end
    if expected ~= current.revision then return failure("CONFLICT", "withdraw revision differs from the pending request", M.view(current)) end
    local settled, settle_error = settle(tx, current, "withdrawn", nil, nil, nil, actor, "withdrawn by the requester", now)
    if not settled then return storage(settle_error or "withdraw request") end
    return success({withdrawn = true, request = M.view(settled)}, false)
end
-- The effect owner's view of an approved decision under the current
-- authority: the caller must hold the consume action, name the exact
-- proposal digest and present the incarnation it observed. An observation
-- of an older authority, or a decision made under one that no effect owner
-- has validated against the current one, asks for revalidation and changes
-- nothing; the reply names the current incarnation to validate against.
local function effect_view(tx: sql.Transaction, actor: string, object: Object, now: integer): (Row?, integer?, Result?)
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return nil, nil, failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return nil, nil, failure("INVALID_ARGUMENT", "proposal_digest is required") end
    local observed = bounds.integer(object.owner_incarnation)
    if not observed or observed < 1 then return nil, nil, failure("INVALID_ARGUMENT", "owner_incarnation must be the incarnation the effect owner observed") end
    local row, load_error = load(tx, approval_id)
    if load_error then return nil, nil, storage(load_error) end
    if not row then return nil, nil, failure("NOT_FOUND", "approval request does not exist") end
    if not security.can(M.CONSUME, text(row.workspace_id) or "") then return nil, nil, failure("DENIED", "caller is not an effect owner for workspace " .. tostring(row.workspace_id)) end
    if row.proposal_digest ~= proposal_digest or (object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest) then return nil, nil, failure("CONFLICT", "effect digest does not match the recorded review", M.view(row)) end
    local scope = bounds.object(row.contract.scope)
    local scope_type = scope and bounds.id(scope.type) or nil
    if not scope or not scope_type then return nil, nil, storage("approval scope is corrupt") end
    local registered, scope_error = resources.scope(scope_type)
    if not registered then return nil, nil, failure("INVALID_STATE", scope_error or "scope adapter is unavailable") end
    if row.contract_version == lifecycle.VERSION and (scope.adapter_version ~= registered.version or scope.adapter_digest ~= registered.digest) then
        return nil, nil, failure("INVALID_STATE", "reviewed scope adapter changed", M.view(row))
    end
    local owner = text(row.owner_node)
    if not owner then return nil, nil, storage("approval request has no owner node") end
    local current, unavailable = incarnation(tx, owner)
    if not current then return nil, nil, unavailable end
    if observed ~= current then
        return nil, nil, failure("REVALIDATE", "authority incarnation is " .. tostring(current) .. ", not " .. tostring(observed), {request = M.view(row), current_incarnation = current})
    end
    if row.state ~= "decided" or row.decision ~= "approved" then return nil, nil, failure("INVALID_STATE", "request is not approved", M.view(row)) end
    return row, current, nil
end
-- revalidate: after an authority restart the effect owner re-checks the
-- decision in its own domain and records that it holds under the current
-- incarnation; consumption under that incarnation is then possible.
local function op_revalidate(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "owner_incarnation", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if row.validated_incarnation == current then return success(M.view(row), true) end
    local update_error = store.validate_effect(tx, row.approval_id, current, actor, stamp(now))
    if update_error then return storage("record validation") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(M.view(updated), false)
end
-- consume: the effect owner binds an approved decision to one effect
-- identity. A decision made under an earlier authority incarnation must
-- have been revalidated under the current one first.
local function op_consume(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "effect_key", "owner_incarnation", "reviewed_digest"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local effect_key = bounds.id(object.effect_key)
    if not effect_key then return failure("INVALID_ARGUMENT", "effect_key is not an identifier") end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if row.owner_incarnation ~= current and row.validated_incarnation ~= current then
        return failure("REVALIDATE", "decision was made under authority incarnation " .. tostring(row.owner_incarnation) .. "; validate it under " .. tostring(current), {request = M.view(row), current_incarnation = current})
    end
    local consumed = text(row.consumed_effect)
    if consumed then
        if consumed == effect_key and row.consumer_id == actor then return success(M.view(row), true) end
        return failure("CONFLICT", "approval was consumed by " .. tostring(row.consumer_id) .. " for effect " .. consumed, M.view(row))
    end
    if row.effect_admission_ms and row.effect_admission_ms <= now then return failure("INVALID_STATE", "effect admission deadline has passed", M.view(row)) end
    local bound_effect = row.effect
    if bound_effect.state ~= "authorized" and bound_effect.state ~= "reserved" then return failure("INVALID_STATE", "effect is not authorized", M.view(row)) end
    local bound = (row.contract_version ~= 1 and bound_effect.destination ~= nil) or bound_effect.state == "reserved"
    if bound and bound_effect.effect_id ~= effect_key then return failure("CONFLICT", "effect identity differs from the reviewed continuation or reservation", M.view(row)) end
    local lifecycle_error = lifecycle.consume(tx, row.approval_id, actor, effect_key, current, stamp(now), bound)
    if lifecycle_error then return storage(lifecycle_error) end
    local update_error = store.consume(tx, row.approval_id, actor, effect_key, stamp(now))
    if update_error then return storage("record consumption") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(M.view(updated), false)
end
local function op_end(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"approval_id", "expected_revision", "proposal_digest", "reviewed_digest", "outcome", "reason"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local approval_id, outcome = bounds.id(object.approval_id), bounds.member(object.outcome, {"superseded", "invalidated"})
    if not approval_id or not outcome then return failure("INVALID_ARGUMENT", "approval_id and terminal outcome are required") end
    local row, err = load(tx, approval_id)
    if err then return storage(err) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if row.requester_id ~= actor and not security.can(M.MANAGE, row.workspace_id) then return failure("DENIED", "caller cannot end this request") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or object.proposal_digest ~= row.proposal_digest or ((row.contract.reviewed_required == true or object.reviewed_digest ~= nil) and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "terminal review differs", M.view(row)) end
    if row.state ~= "pending" then return success(M.view(row), true) end
    if row.revision ~= expected then return failure("CONFLICT", "terminal revision differs", M.view(row)) end
    local reason = object.reason == nil and outcome or bounds.text(object.reason, 4096)
    if not reason then return failure("INVALID_ARGUMENT", "reason must be bounded text") end
    local settled, settle_error = settle(tx, row, outcome, nil, nil, nil, actor, reason, now)
    if not settled then return storage(settle_error or "end request") end
    return success(M.view(settled), false)
end
local function op_effect(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"operation", "approval_id", "proposal_digest", "reviewed_digest", "effect_key", "owner_incarnation", "expected_revision", "state", "result"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    if object.operation == "claim" then
        return op_consume(tx, actor, {approval_id = object.approval_id, proposal_digest = object.proposal_digest,
            effect_key = object.effect_key, owner_incarnation = object.owner_incarnation, reviewed_digest = object.reviewed_digest}, now, nil)
    end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is required") end
    local row, err = load(tx, approval_id)
    if err then return storage(err) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    local ended = row.effect.state == "canceled"
    local receiver = ended and type(row.effect.destination) == "string" and security.can(M.OWN, row.effect.destination)
    if not receiver and (not security.can(M.CONSUME, row.workspace_id) or (row.requester_id ~= actor and row.consumer_id ~= actor)) then return failure("DENIED", "caller does not own this effect") end
    if object.proposal_digest ~= row.proposal_digest or (object.reviewed_digest ~= nil and object.reviewed_digest ~= row.reviewed_digest) then return failure("CONFLICT", "effect review differs", M.view(row)) end
    local effect = row.effect
    if object.operation == "read" then return success(M.view(row), false) end
    if object.operation == "complete" then
        local receipt = bounds.object(object.result)
        local encoded, encode_error = canonical.encode(receipt, 8192)
        if not receipt or not encoded then return failure("INVALID_ARGUMENT", encode_error or "effect result is required") end
        local state = ended and "canceled" or bounds.member(object.state == nil and (receipt.ok == false and "failed" or "succeeded") or object.state, {"succeeded", "failed", "canceled", "uncertain"})
        if not state then return failure("INVALID_ARGUMENT", "completion requires a terminal effect state") end
        if row.effect_completed_at then
            if row.effect_result_json ~= encoded or effect.state ~= state then return failure("CONFLICT", "effect already has a different receipt", M.view(row)) end
            return success(M.view(row), true)
        end
        if not ended and (row.consumer_id ~= actor or row.consumed_effect ~= object.effect_key) then return failure("CONFLICT", "effect was not admitted by this receiver", M.view(row)) end
        if state == "uncertain" and effect.state == "uncertain" and canonical.encode(effect.receipt, 8192) == encoded then return success(M.view(row), true) end
        local completion_error: string? = nil
        if state == "uncertain" then completion_error = lifecycle.complete(tx, approval_id, state, encoded, stamp(now))
        else completion_error = store.complete_effect(tx, approval_id, stamp(now), encoded, stamp(now), state) end
        if completion_error then return storage(completion_error) end
    elseif object.operation == "start" or object.operation == "reconcile" then
        local current, refused = incarnation(tx, row.owner_node)
        if not current then return refused or storage("read authority") end
        if object.owner_incarnation ~= current or (row.owner_incarnation ~= current and row.validated_incarnation ~= current) then return failure("REVALIDATE", "effect needs current incarnation validation", {request = M.view(row), current_incarnation = current}) end
        if effect.consumer_id ~= actor or row.consumed_effect ~= object.effect_key then return failure("CONFLICT", "effect is not admitted by this receiver") end
        local state = object.operation == "start" and "started" or bounds.member(object.state, {"started", "uncertain"})
        if not state then return failure("INVALID_ARGUMENT", "reconciliation state must be started or uncertain") end
        if effect.state == state then return success(M.view(row), true) end
        if object.expected_revision ~= effect.revision then return failure("CONFLICT", "effect revision differs", M.view(row)) end
        if effect.state ~= "admitted" and effect.state ~= "started" and effect.state ~= "uncertain" then return failure("INVALID_STATE", "effect cannot start or reconcile") end
        local _, update_error = tx:execute("UPDATE bee_approval_effects SET state = ?, revision = revision + 1, owner_incarnation = ?, updated_at = ? WHERE approval_id = ?", {state, current, stamp(now), approval_id})
        if update_error then return storage("update effect") end
    else return failure("INVALID_ARGUMENT", "effect operation must be read, claim, start, complete or reconcile") end
    local updated, update_error = load(tx, approval_id)
    if not updated then return storage(update_error or "read effect") end
    return success(M.view(updated), false)
end
local function op_grant(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"operation", "grant_id", "expected_revision", "subject", "scope", "effect_key", "owner_incarnation", "reviewed_digest"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local id = bounds.id(object.grant_id)
    if not id then return failure("INVALID_ARGUMENT", "grant_id is required") end
    local rows, err = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?", {id})
    if not rows or err then return storage("read grant") end
    local grant = #rows == 1 and bounds.object(rows[1]) or nil
    if not grant then return failure("NOT_FOUND", "grant does not exist") end
    local approval_id = bounds.id(grant.approval_id)
    local row, row_error = approval_id and load(tx, approval_id) or nil, nil
    if not row then return storage(row_error or "grant source is missing") end
    local can_revoke = row.requester_id == actor or security.can(M.MANAGE, row.workspace_id)
    if object.operation == "revoke" then
        local may_decide, policy_error = eligible(actor, row)
        if policy_error then return storage(policy_error) end
        if not can_revoke and not may_decide then return failure("DENIED", "caller cannot revoke this grant") end
        if grant.state == "revoked" then return success(grant, true) end
        if object.expected_revision ~= grant.revision then return failure("CONFLICT", "grant revision differs", grant) end
        local _, revoke_error = tx:execute("UPDATE bee_approval_grants SET state = 'revoked', revision = revision + 1 WHERE grant_id = ?", {id})
        if revoke_error then return storage("revoke grant") end
        local _, fence_error = tx:execute("UPDATE bee_approval_effects SET state = 'canceled', revision = revision + 1, updated_at = ? WHERE approval_id = ? AND state IN ('authorized','reserved')", {stamp(now), approval_id})
        if fence_error then return storage("fence reserved effect") end
        local revision = bounds.integer(grant.revision)
        if not revision then return storage("grant revision is corrupt") end
        local notification_error = lifecycle.grant_revoked(tx, row.approval_id, row.requester_id, revision + 1, stamp(now))
        if notification_error then return storage(notification_error) end
        return success({grant_id = id, state = "revoked", already_admitted = row.consumed_effect ~= nil}, false)
    end
    if row.requester_id ~= actor or not security.can(M.CONSUME, row.workspace_id) then return failure("DENIED", "caller cannot use this grant") end
    local subject = canonical.encode(object.subject)
    local scope = canonical.encode(object.scope)
    if subject ~= grant.subject_json or scope ~= grant.scope_json then return failure("CONFLICT", "grant subject or exact scope differs") end
    local deadline = bounds.integer(grant.until_ms)
    if grant.state == "active" and deadline and deadline <= now then
        local _, expire_error = tx:execute("UPDATE bee_approval_grants SET state = 'expired', revision = revision + 1 WHERE grant_id = ?", {id})
        if expire_error then return storage("expire grant") end
        return refusal("INVALID_STATE", "grant expired", {grant_id = id, state = "expired"})
    end
    if object.operation == "admit" then
        if row.consumed_effect == nil and object.expected_revision ~= grant.revision then return failure("CONFLICT", "grant revision differs", grant) end
        return op_consume(tx, actor, {approval_id = approval_id, proposal_digest = row.proposal_digest,
            effect_key = object.effect_key, owner_incarnation = object.owner_incarnation, reviewed_digest = object.reviewed_digest}, now, nil)
    end
    if grant.state ~= "active" then return failure("INVALID_STATE", "grant is " .. tostring(grant.state), grant) end
    if object.operation == "check" then return success(grant, false) end
    if object.expected_revision ~= grant.revision then return failure("CONFLICT", "grant revision differs", grant) end
    local state: string? = nil
    local effect_state = row.effect.state
    if object.operation == "reserve" then
        if effect_state == "reserved" and row.effect.effect_id == object.effect_key then return success(grant, true) end
        if effect_state ~= "authorized" then return failure("INVALID_STATE", "effect cannot reserve") end
        if row.contract_version ~= 1 and row.effect.destination ~= nil and row.effect.effect_id ~= object.effect_key then return failure("CONFLICT", "effect identity differs") end
        state = "reserved"
    elseif object.operation == "release" then
        if effect_state ~= "reserved" or row.effect.effect_id ~= object.effect_key then return failure("CONFLICT", "effect reservation differs") end
        state = "authorized"
    else return failure("INVALID_ARGUMENT", "grant operation must be check, reserve, admit, release or revoke") end
    local effect_key = bounds.id(object.effect_key)
    if not effect_key then return failure("INVALID_ARGUMENT", "effect_key is required") end
    local _, update_error = tx:execute("UPDATE bee_approval_effects SET effect_id = ?, state = ?, revision = revision + 1, updated_at = ? WHERE approval_id = ?", {effect_key, state, stamp(now), approval_id})
    if update_error then return storage("reserve or release effect") end
    local _, revision_error = tx:execute("UPDATE bee_approval_grants SET revision = revision + 1 WHERE grant_id = ?", {id})
    if revision_error then return storage("advance grant revision") end
    local updated, read_error = tx:query("SELECT * FROM bee_approval_grants WHERE grant_id = ?", {id})
    if not updated or read_error then return storage("read updated grant") end
    return success(updated[1], false)
end
local function op_events(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"cursor", "limit", "destination", "acknowledge"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local destination = object.destination == nil and "requester:" .. actor or bounds.id(object.destination)
    if not destination then return failure("INVALID_ARGUMENT", "destination is invalid") end
    if destination ~= "requester:" .. actor then
        local consumer, err = resources.consumer(destination)
        if not consumer then return failure("INVALID_ARGUMENT", err or "consumer is missing") end
        if not security.can(M.OWN, destination) then return failure("DENIED", "caller cannot read this destination's events") end
    end
    local acknowledged = bounds.array(object.acknowledge == nil and {} or object.acknowledge, 64)
    if not acknowledged then return failure("INVALID_ARGUMENT", "acknowledge must be an event id list") end
    for _, raw in ipairs(acknowledged) do
        local id = bounds.id(raw)
        if not id then return failure("INVALID_ARGUMENT", "acknowledge needs event ids") end
        local _, err = tx:execute("UPDATE bee_approval_events SET acknowledged_at = COALESCE(acknowledged_at, ?) WHERE event_id = ? AND destination = ?", {stamp(now), id, destination})
        if err then return storage("acknowledge notification") end
    end
    local cursor = bounds.count(object.cursor == nil and 0 or object.cursor)
    local limit = bounds.integer(object.limit == nil and 64 or object.limit)
    if not cursor or not limit or limit < 1 or limit > 64 then return failure("INVALID_ARGUMENT", "cursor and limit are invalid") end
    local rows, err = tx:query("SELECT * FROM bee_approval_events WHERE destination = ? AND seq > ? ORDER BY seq LIMIT ?", {destination, cursor, limit})
    if not rows or err then return storage("read lifecycle events") end
    local events: {Object} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local sequence = row and bounds.count(row.seq) or nil
        local body = row and type(row.body_json) == "string" and bounds.object(json.decode(row.body_json)) or nil
        if not row or not sequence or not body then return storage("lifecycle event is corrupt") end
        events[#events + 1] = {event_id = row.event_id, sequence = sequence, kind = row.kind, body = body, acknowledged_at = row.acknowledged_at}
        cursor = sequence
    end
    return success({events = events, cursor = cursor}, false)
end
local function op_effect_queue(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"destination", "limit", "phase"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local destination = bounds.id(object.destination)
    local limit = bounds.integer(object.limit == nil and 16 or object.limit)
    local phase = bounds.member(object.phase == nil and "all" or object.phase, {"all", "ready", "ended"})
    if not destination or not limit or limit < 1 or limit > 64 or not phase then return failure("INVALID_ARGUMENT", "destination, phase and limit are invalid") end
    local consumer, consumer_error = resources.consumer(destination)
    if not consumer then return failure("INVALID_ARGUMENT", consumer_error or "effect consumer is missing") end
    if not security.can(M.OWN, destination) then return failure("DENIED", "caller cannot enumerate this effect destination") end
    local rows, err = tx:query([[SELECT r.* FROM bee_approval_requests r JOIN bee_approval_effects e ON e.approval_id = r.approval_id
        WHERE e.destination = ? AND r.state <> 'pending' AND r.effect_completed_at IS NULL
        AND (r.consumer_id IS NULL OR r.consumer_id = r.requester_id OR r.consumer_id = ?)
        AND (? = 'all' OR (? = 'ready' AND e.state <> 'canceled') OR (? = 'ended' AND e.state = 'canceled'))
        ORDER BY r.approval_id LIMIT ?]], {destination, actor, phase, phase, phase, limit})
    if not rows or err then return storage("read effect destination queue") end
    local effects: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage(decode_error or "decode effect") end
        if row.proposal.ref ~= consumer.operation_ref then return storage("effect destination operation differs") end
        effects[#effects + 1] = M.view(row)
    end
    return success({effects = effects}, false)
end
local function may_read(actor: string, row: Row): (boolean, string?)
    if row.requester_id == actor then return true, nil end
    if security.can(M.MANAGE, text(row.workspace_id) or "") then return true, nil end
    return eligible(actor, row)
end
local function op_read(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    local allowed, policy_error = may_read(actor, row)
    if policy_error then return storage(policy_error) end
    if not allowed then return failure("DENIED", "caller may not read this request") end
    return success(M.view(row), false)
end
-- inbox: an approver's bounded catch-up over one workspace's changes; a
-- cursor older than the retained window asks for a reset instead of
-- skipping changes.
local function op_inbox(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "after_seq", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return failure("INVALID_ARGUMENT", "workspace_id is not an identifier") end
    local after = bounds.integer(object.after_seq == nil and 0 or object.after_seq)
    if not after or after < 0 then return failure("INVALID_ARGUMENT", "after_seq must be a nonnegative integer") end
    local limit = bounds.integer(object.limit == nil and M.MAX_INBOX or object.limit)
    if not limit or limit < 1 or limit > M.MAX_INBOX then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(M.MAX_INBOX)) end
    if not security.can(M.DECIDE, workspace_id) then return failure("DENIED", "caller may not read the inbox of workspace " .. workspace_id) end
    local raw_oldest, oldest_error = store.oldest_inbox(tx, workspace_id)
    if oldest_error then return storage("read inbox") end
    local oldest_seq = raw_oldest == nil and nil or integer(raw_oldest)
    if raw_oldest ~= nil and oldest_seq == nil then return storage("oldest inbox position is corrupt") end
    if oldest_seq and after > 0 and after < oldest_seq - 1 then return failure("RESET_REQUIRED", "changes before " .. tostring(oldest_seq) .. " are compacted", {oldest_seq = oldest_seq}) end
    local rows, rows_error = store.inbox_after(tx, workspace_id, after, limit)
    if rows_error or not rows then return storage("read inbox") end
    local changes: {Object} = {}
    local next_seq = after
    for _, raw in ipairs(rows) do
        local change = bounds.object(raw)
        local sequence = change and bounds.count(change.seq)
        local approval_id = change and bounds.id(change.approval_id)
        local revision = change and bounds.count(change.revision)
        local at = change and bounds.timestamp(change.at)
        if not sequence or sequence <= next_seq or not approval_id or not revision or revision < 1 or not at then
            return storage("approval inbox entry is corrupt")
        end
        next_seq = sequence
        local row, load_error = load(tx, approval_id)
        if load_error then return storage(load_error) end
        if row then
            local visible, policy_error = eligible(actor, row)
            if policy_error then return storage(policy_error) end
            if visible then changes[#changes + 1] = {seq = sequence, approval_id = approval_id, revision = row.revision, at = at, request = M.view(row)} end
        end
    end
    return success({changes = changes, next_seq = next_seq, more = #rows == limit}, false)
end
-- list: the requester's own requests, newest first, bounded.
-- A visibility-scoped snapshot/feed adapter over the approval owner's existing
-- transactional ledger. It never copies approval authority into the sync store.
local function feed_scope(actor: string, workspace: string): (string?, string?, string?, Result?)
    local native, native_error = node()
    if not native then return nil, nil, nil, failure("UNAVAILABLE", "native node identity unavailable: " .. tostring(native_error)) end
    if not security.can(M.DECIDE, workspace) then return nil, nil, nil, failure("DENIED", "caller may not read this workspace inbox") end
    local policies, policy_error = resources.policies()
    if not policies then return nil, nil, nil, storage(policy_error or "read approver policies") end
    local encoded, encode_error = canonical.encode({actor = actor, definition_id = authenticated_definition(actor),
        workspace = workspace, policies = policies})
    if not encoded then return nil, nil, nil, storage(encode_error or "encode approval visibility") end
    local scope, scope_error = hash.sha256(encoded)
    local feed, feed_error = hash.sha256(workspace)
    if not scope or scope_error or not feed or feed_error then return nil, nil, nil, storage("measure approval visibility") end
    return "approvals." .. feed, scope, native, nil
end
local function inbox_head(tx: sql.Transaction): (integer?, Result?)
    local raw, exists, err = store.inbox_head(tx)
    if err then return nil, storage("read inbox watermark") end
    if not exists then return 0, nil end
    local cursor = bounds.count(raw)
    if cursor == nil then return nil, storage("inbox watermark is corrupt") end
    return cursor, nil
end
local function op_feed_snapshot(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "limit", "after_key", "expected_cursor", "expected_scope_revision"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local workspace = bounds.id(object.workspace_id)
    local parsed_limit = bounds.integer(object.limit == nil and 64 or object.limit)
    local after = object.after_key == nil and "" or bounds.id(object.after_key)
    if not workspace then return failure("INVALID_ARGUMENT", "invalid snapshot workspace") end
    if not parsed_limit then return failure("INVALID_ARGUMENT", "invalid snapshot limit") end
    local fetch_limit: integer = parsed_limit + 1
    if parsed_limit < 1 or parsed_limit > 64 then return failure("INVALID_ARGUMENT", "snapshot limit must be between 1 and 64") end
    if not after then return failure("INVALID_ARGUMENT", "invalid snapshot after_key") end
    local limit: integer = parsed_limit
    local feed, scope, owner, refused = feed_scope(actor, workspace)
    if not feed or not scope or not owner then return refused or storage("read feed scope") end
    local cursor, cursor_error = inbox_head(tx)
    if not cursor then return cursor_error or storage("read inbox watermark") end
    if object.expected_cursor ~= nil and bounds.count(object.expected_cursor) == nil then return failure("INVALID_ARGUMENT", "invalid expected_cursor") end
    if object.expected_scope_revision ~= nil and (type(object.expected_scope_revision) ~= "string" or
        #object.expected_scope_revision ~= 64 or not object.expected_scope_revision:match("^[0-9a-f]+$")) then
        return failure("INVALID_ARGUMENT", "invalid expected_scope_revision")
    end
    if after ~= "" and (object.expected_cursor == nil or object.expected_scope_revision == nil) then return failure("INVALID_ARGUMENT", "snapshot continuation requires cursor and scope revision") end
    if (object.expected_cursor ~= nil and object.expected_cursor ~= cursor) or
        (object.expected_scope_revision ~= nil and object.expected_scope_revision ~= scope) then
        return failure("RESET_REQUIRED", "snapshot changed; restart from its first page")
    end
    local rows, err = store.snapshot(tx, workspace, after, fetch_limit)
    if err or not rows then return storage("read approval snapshot") end
    local items: {Object} = {}
    local next_key: string? = nil
    local page_bytes, truncated = 0, false
    for index, raw in ipairs(rows) do
        if index > limit then break end
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode approval snapshot: " .. tostring(decode_error)) end
        local raw_row = bounds.object(raw)
        local sequence = raw_row and bounds.count(raw_row.last_sequence)
        if not sequence then return storage("approval projection has no valid ledger position") end
        local visible, policy_error = eligible(actor, row)
        if policy_error then return storage(policy_error) end
        if visible then
            local item: Object = {schema = "bee.sync-projection@1", owner_id = owner, feed = feed,
                key = row.approval_id, revision = row.revision, value = M.view(row), tombstone = false,
                sequence = sequence, updated_at = row.updated_at}
        local encoded = canonical.encode(item, 196608)
            if not encoded then return storage("encode approval projection") end
            if #encoded > 196608 then return failure("CAPACITY_EXHAUSTED", "approval projection exceeds feed capacity") end
            if page_bytes + #encoded > 196608 then truncated = true; break end
            page_bytes = page_bytes + #encoded
            items[#items + 1] = item
        end
        next_key = text(row.approval_id)
    end
    local _, checked_scope, checked_owner, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope or checked_owner ~= owner then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-snapshot@1", owner_id = owner, feed = feed, cursor = cursor,
        earliest_cursor = 0, scope_revision = scope, items = items, complete = not truncated and #rows <= limit,
        next_key = (truncated or #rows > limit) and next_key or nil, reset_required = false}, false)
end
local function op_feed_read_after(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "cursor", "limit", "expected_scope_revision"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local workspace, cursor = bounds.id(object.workspace_id), bounds.count(object.cursor)
    if not workspace or not cursor then return failure("INVALID_ARGUMENT", "invalid feed request") end
    if type(object.expected_scope_revision) ~= "string" or #object.expected_scope_revision ~= 64 or
        not object.expected_scope_revision:match("^[0-9a-f]+$") then return failure("INVALID_ARGUMENT", "invalid expected_scope_revision") end
    local feed, scope, owner, refused = feed_scope(actor, workspace)
    if not feed or not scope or not owner then return refused or storage("read feed scope") end
    if object.expected_scope_revision ~= scope then return failure("RESET_REQUIRED", "take a snapshot of the current approval visibility") end
    local page = op_inbox(tx, actor, {workspace_id = workspace, after_seq = cursor, limit = object.limit}, now, nil)
    if not page.ok then return page end
    local value = bounds.object(page.value)
    if not value then return storage("read approval page") end
    local changes = value.changes
    local events: {Object} = {}
    local page_bytes, truncated = 0, false
    local next_cursor = value.next_seq
    for _, change in ipairs(changes) do
        local request = bounds.object(change.request)
        if not request then return storage("read approval change") end
        local item: Object = {schema = "bee.sync-event@1", owner_id = owner, feed = feed, sequence = change.seq,
            event_id = tostring(change.approval_id) .. "/" .. tostring(change.seq), event_type = "approval.changed",
            projection_key = change.approval_id, revision = request.revision, tombstone = false,
            payload = {schema_revision = "bee.approval-projection@1", request = request}, committed_at = change.at}
            local encoded = canonical.encode(item, 196608)
        if not encoded then return storage("encode approval event") end
        if #encoded > 196608 then return failure("CAPACITY_EXHAUSTED", "approval event exceeds feed capacity") end
        if page_bytes + #encoded > 196608 then
            truncated = true
            next_cursor = events[#events].sequence
            break
        end
        page_bytes = page_bytes + #encoded
        events[#events + 1] = item
    end
    local head, head_error = inbox_head(tx)
    if not head then return head_error or storage("read inbox watermark") end
    if cursor > head then return failure("INVALID_ARGUMENT", "cursor is ahead of the inbox") end
    local _, checked_scope, checked_owner, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope or checked_owner ~= owner then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-page@1", owner_id = owner, feed = feed, scope_revision = scope,
        events = events, next_cursor = next_cursor, more = truncated or value.more, head_cursor = head,
        earliest_cursor = 0, reset_required = false}, false)
end
local function op_list(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local limit = bounds.integer(object.limit == nil and M.MAX_LIST or object.limit)
    if not limit or limit < 1 or limit > M.MAX_LIST then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(M.MAX_LIST)) end
    local workspace_id: string? = nil
    if object.workspace_id ~= nil then
        workspace_id = bounds.id(object.workspace_id)
        if not workspace_id then return failure("INVALID_ARGUMENT", "workspace_id is not an identifier") end
    end
    local rows, err = store.list(tx, actor, workspace_id, limit)
    if err or not rows then return storage("list approval requests") end
    local views: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode approval list: " .. tostring(decode_error)) end
        views[#views + 1] = M.view(row)
    end
    return success({requests = views}, false)
end
-- reconcile: the owner expires every pending request past its deadline and
-- forgets requests whose lifetime ended a retention window ago and whose
-- deliveries are all acknowledged, together with their history, inbox
-- changes and deliveries. An idempotency key older than that horizon can
-- create a fresh request; that is the advertised dedupe horizon.
local function op_reconcile(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    if not security.can(M.OWN, "*") then return failure("DENIED", "caller is not the approval owner") end
    local due, due_error = store.due(tx, now, M.EXPIRE_BOUND)
    if due_error or not due then return storage("read due requests") end
    local expired = 0
    for _, raw in ipairs(due) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode due approval: " .. tostring(decode_error)) end
        local settled, settle_error, expired_now = expire_if_due(tx, row, now)
        if not settled then return storage(settle_error or "expire request") end
        if expired_now then expired = expired + 1 end
    end
    local expired_effects, effect_error = lifecycle.expire_effects(tx, now, stamp(now))
    if expired_effects == nil then return storage(effect_error or "expire effect admission") end
    local horizon = now - M.RETENTION_MS
    local stale, stale_error = store.retained(tx, horizon, now, M.EXPIRE_BOUND)
    if stale_error or not stale then return storage("read retained requests") end
    local forgotten = 0
    for _, raw in ipairs(stale) do
        local retained = bounds.object(raw)
        local approval_id = retained and bounds.id(retained.approval_id)
        if not approval_id then return storage("retained approval identity is corrupt") end
        local delete_error = store.forget(tx, approval_id)
        if delete_error then return storage("forget retained request") end
        forgotten = forgotten + 1
    end
    local window_error = store.forget_windows(tx, horizon)
    if window_error then return storage(window_error) end
    return success({expired = expired, expired_effects = expired_effects, forgotten = forgotten, more = #due == M.EXPIRE_BOUND or expired_effects == M.EXPIRE_BOUND}, expired == 0 and forgotten == 0 and expired_effects == 0)
end
-- establish: the authority process advances the incarnation once per start,
-- before any request is served under it. Delivery ownership is separate.
function M.establish(db: sql.DB): (integer?, string?)
    local owner, node_error = node()
    if not owner then return nil, node_error or "native node identity unavailable" end
    local result = transaction.write(db, M.LABEL, function(tx: sql.Transaction): Result
        local raw_current, exists, err = store.authority(tx, owner)
        if err then return storage("read authority incarnation") end
        local next_incarnation = 1
        if exists then
            local advanced, advance_error = advance_incarnation(raw_current)
            if advanced == nil then return storage(advance_error or "authority incarnation is corrupt") end
            next_incarnation = advanced
        end
        local write_error = store.write_authority(tx, owner, next_incarnation, stamp(now_ms()))
        if write_error then return storage("establish authority incarnation") end
        return success(next_incarnation, false)
    end)
    if not result.ok then return nil, result.message end
    return integer(result.value), nil
end
function M.node(): (string?, string?)
    return node()
end
local function op_attention_count(tx: sql.Transaction, actor: string, object: Object, now: integer, _: Object?): Result
    local workspace = bounds.id(object.workspace_id)
    if not workspace or bounds.fields(object, {"workspace_id"}) then return failure("INVALID_ARGUMENT", "attention count needs one workspace") end
    if not security.can("bee.approvals.attention", workspace) then return failure("DENIED", "caller may not count this workspace's attention") end
    local count, count_error = store.attention_count(tx, workspace, now)
    if count_error or count == nil then return storage(count_error or "count attention") end
    return success({count = count}, false)
end
local function op_node_summary(tx: sql.Transaction, _: string, object: Object, now: integer, _prepared: Object?): Result
    if next(object) ~= nil then return failure("INVALID_ARGUMENT", "node summary accepts an empty object") end
    if not security.can("bee.approvals.summary", "node") then return failure("DENIED", "caller may not summarize node approvals") end
    local current, node_error = node()
    if not current then return failure("UNAVAILABLE", node_error or "node identity is unavailable") end
    local count, count_error = store.node_pending_count(tx, current, now)
    if count == nil then return storage(count_error or "count node pending approvals") end
    return success({pending_approvals = count}, false)
end
local function op_runtime_lease(tx: sql.Transaction, actor: string, request: Object, now: integer, prepared: Object?): Result
    if bounds.fields(request, {"operation", "lease_ref", "workspace_id", "tool", "input_digest", "effect_key"}) then return failure("INVALID_ARGUMENT", "runtime lease request has unknown fields") end
    local operation = bounds.member(request.operation, {"grant", "check", "use", "revoke", "list"})
    if not operation then return failure("INVALID_ARGUMENT", "runtime lease operation is invalid") end
    if operation == "list" then
        local workspace = bounds.id(request.workspace_id)
        if not workspace or not security.can(M.CONSUME, workspace) then return failure("DENIED", "runtime lease list needs workspace consume authority") end
        local rows, err = tx:query("SELECT lease_ref, subject, workspace_id, tool, input_digest, expires_ms, max_uses, revoked_at FROM bee_approval_runtime_leases WHERE subject = ? AND workspace_id = ? ORDER BY lease_ref LIMIT 64", {actor, workspace})
        if not rows or err then return storage("list runtime leases") end
        return success({leases = rows}, false)
    end
    local ref = bounds.id(request.lease_ref)
    if not ref then return failure("INVALID_ARGUMENT", "lease_ref is required") end
    if operation == "grant" then
        local source, err = load(tx, ref)
        if not source then return failure("NOT_FOUND", err or "lease source approval is missing") end
        local ceiling, invalid = runtime_lease.decode(source.proposal.payload)
        if source.proposal.ref ~= runtime_lease.REF or not ceiling then return failure("INVALID_ARGUMENT", invalid or "approval is not a runtime lease") end
        if actor ~= ceiling.subject or source.requester_id ~= actor or source.workspace_id ~= ceiling.workspace_id then return failure("DENIED", "runtime lease belongs to another subject") end
        local current, unavailable = incarnation(tx, source.owner_node)
        if not current then return unavailable or storage("runtime lease authority") end
        if source.owner_incarnation ~= current and source.validated_incarnation ~= current then return failure("REVALIDATE", "runtime lease approval needs revalidation after restart", {current_incarnation = current}) end
        local consumed = op_consume(tx, actor, {approval_id = ref, proposal_digest = source.proposal_digest, effect_key = "runtime-lease:" .. ref, owner_incarnation = current}, now, nil)
        if not consumed.ok then return consumed end
        if ceiling.expires_ms <= now then return failure("INVALID_STATE", "runtime lease expired") end
        local _, stored = tx:execute("INSERT INTO bee_approval_runtime_leases (lease_ref, owner_node, subject, workspace_id, tool, input_digest, expires_ms, max_uses, source_digest) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(lease_ref) DO NOTHING",
            {ref, source.owner_node, actor, ceiling.workspace_id, ceiling.tool, ceiling.input_digest, ceiling.expires_ms, ceiling.max_uses, source.proposal_digest})
        if stored then return storage("grant runtime lease") end
        return success({lease_ref = ref, ceiling = ceiling}, consumed.replayed)
    end
    local rows, err = tx:query("SELECT * FROM bee_approval_runtime_leases WHERE lease_ref = ?", {ref})
    local row = rows and bounds.object(rows[1])
    if err then return storage("read runtime lease") end
    if not row then return failure("NOT_FOUND", "runtime lease is missing") end
    local workspace = bounds.id(row.workspace_id)
    if not workspace or not security.can(M.CONSUME, workspace) then return failure("DENIED", "runtime lease needs workspace consume authority") end
    if operation == "revoke" then
        if actor ~= row.subject and not security.can(M.MANAGE, workspace) then return failure("DENIED", "runtime lease belongs to another subject") end
        local _, failed = tx:execute("UPDATE bee_approval_runtime_leases SET revoked_at = COALESCE(revoked_at, ?) WHERE lease_ref = ?", {stamp(now), ref})
        if failed then return storage("revoke runtime lease") end
        return success({lease_ref = ref, revoked = true}, row.revoked_at ~= nil)
    end
    if actor ~= row.subject or request.workspace_id ~= workspace then return failure("DENIED", "runtime lease subject or workspace differs") end
    local expires, maximum = bounds.count(row.expires_ms), bounds.count(row.max_uses)
    if row.revoked_at ~= nil or not expires or expires <= now or not maximum then return failure("DENIED", "runtime lease is revoked or expired") end
    local counts, count_error = tx:query("SELECT COUNT(*) AS count FROM bee_approval_runtime_lease_uses WHERE lease_ref = ?", {ref})
    local count = counts and bounds.object(counts[1])
    local used = count and bounds.count(count.count)
    if count_error or used == nil then return storage("count runtime lease consumption") end
    if operation == "check" then
        if used >= maximum then return failure("DENIED", "runtime lease use limit is exhausted") end
        if (request.tool ~= nil and request.tool ~= row.tool) or (request.input_digest ~= nil and request.input_digest ~= row.input_digest) then return failure("DENIED", "runtime lease does not cover this exact tool input") end
        return success({lease_ref = ref, subject = actor, workspace_id = workspace}, false)
    end
    local effect = bounds.id(request.effect_key)
    if not effect or request.tool ~= row.tool or request.input_digest ~= row.input_digest then return failure("DENIED", "runtime lease does not cover this exact tool input") end
    local digest = digest_of({subject = actor, workspace_id = workspace, tool = request.tool, input_digest = request.input_digest})
    if not digest then return failure("INVALID_ARGUMENT", "runtime lease effect cannot be measured") end
    local previous, previous_error = tx:query("SELECT request_digest FROM bee_approval_runtime_lease_uses WHERE lease_ref = ? AND effect_key = ?", {ref, effect})
    if not previous or previous_error then return storage("read runtime lease consumption") end
    if #previous > 0 then
        local stored = bounds.object(previous[1])
        if not stored or stored.request_digest ~= digest then return failure("CONFLICT", "runtime lease effect key changed") end
        return success({lease_ref = ref, consumed = true}, true)
    end
    if used >= maximum then return failure("DENIED", "runtime lease use limit is exhausted") end
    local _, failed = tx:execute("INSERT INTO bee_approval_runtime_lease_uses (lease_ref, effect_key, request_digest) VALUES (?, ?, ?)", {ref, effect, digest})
    if failed then return storage("consume runtime lease") end
    return success({lease_ref = ref, consumed = true}, false)
end

local function op_grant_window(tx: sql.Transaction, actor: string, request: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(request, {"operation", "workspace_id", "grant_id", "after_id"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local owner, node_error = node()
    if not owner then return failure("UNAVAILABLE", node_error or "native node identity is unavailable") end
    local definition = authenticated_definition(actor)
    if request.operation == "list" then
        local workspace = bounds.id(request.workspace_id)
        local after = request.after_id == nil and "" or bounds.id(request.after_id)
        if not workspace or after == nil then return failure("INVALID_ARGUMENT", "workspace_id and optional after_id must be identifiers") end
        if not security.can(M.DECIDE, workspace) then return failure("DENIED", "caller has no approval decision authority in this workspace") end
        local rows, err = store.active_windows(tx, owner, workspace, actor, definition, now, after)
        if not rows or err then return storage(err or "list active approval windows") end
        local grants: {windows.Grant} = {}
        local more = #rows > M.MAX_LIST
        for index, raw in ipairs(rows) do
            if index > M.MAX_LIST then break end
            local grant, decode_error = windows.decode(raw)
            if not grant then return storage(decode_error or "decode approval window") end
            grants[#grants + 1] = grant
        end
        return success({grants = grants, more = more, next_id = more and grants[#grants].grant_id or nil}, false)
    end
    if request.operation ~= "revoke" then return failure("INVALID_ARGUMENT", "operation must be list or revoke") end
    local id = bounds.id(request.grant_id)
    if not id then return failure("INVALID_ARGUMENT", "grant_id must be an identifier") end
    local raw, read_error = store.window(tx, id)
    if read_error then return storage(read_error) end
    if not raw then return failure("NOT_FOUND", "approval window does not exist") end
    local grant, decode_error = windows.decode(raw)
    if not grant then return storage(decode_error or "decode approval window") end
    if grant.owner_node ~= owner or not security.can(M.DECIDE, grant.workspace_id)
        or (request.workspace_id ~= nil and request.workspace_id ~= grant.workspace_id)
        or (actor ~= grant.granted_by and (not definition or definition ~= grant.granted_definition)) then return failure("DENIED", "caller does not own this node's approval window") end
    local revoke_error = store.revoke_window(tx, id, stamp(now))
    if revoke_error then return storage(revoke_error) end
    return success({grant_id = id, revoked = true}, grant.revoked_at ~= nil)
end
operations.effect, operations.events, operations.end_request, operations.grant = op_effect, op_events, op_end, op_grant
operations.grant_window = op_grant_window
operations.runtime_lease = op_runtime_lease
operations.attention_count = op_attention_count
operations.node_summary = op_node_summary
operations.decide_batch = op_decide_batch
operations.request, operations.decide, operations.withdraw, operations.consume, operations.revalidate = op_request, op_decide, op_withdraw, op_consume, op_revalidate
operations.effect_queue = op_effect_queue
operations.read, operations.inbox, operations.list, operations.reconcile = op_read, op_inbox, op_list, op_reconcile
operations.feed_snapshot, operations.feed_read_after = op_feed_snapshot, op_feed_read_after
preparations.request = prepare_request
function M.grant(value: unknown): Reply return run(value, "grant") end
function M.effect(value: unknown): Reply return run(value, "effect") end
function M.events(value: unknown): Reply return run(value, "events") end
function M.end_request(value: unknown): Reply return run(value, "end_request") end
function M.grant_window(value: unknown): Reply return run(value, "grant_window") end
function M.runtime_lease(value: unknown): Reply return run(value, "runtime_lease") end
function M.request(value: unknown): Reply return run(value, "request") end
function M.decide(value: unknown): Reply return run(value, "decide") end
function M.decide_batch(value: unknown): Reply return run(value, "decide_batch") end
function M.withdraw(value: unknown): Reply return run(value, "withdraw") end
function M.consume(value: unknown): Reply return run(value, "consume") end
function M.effect_queue(value: unknown): Reply return run(value, "effect_queue") end
function M.revalidate(value: unknown): Reply return run(value, "revalidate") end
function M.read(value: unknown): Reply return run(value, "read") end
function M.attention_count(value: unknown): Reply return run(value, "attention_count") end
function M.node_summary(value: unknown): Reply return run(value, "node_summary") end
function M.inbox(value: unknown): Reply return run(value, "inbox") end
function M.feed_snapshot(value: unknown): Reply return run(value, "feed_snapshot") end
function M.feed_read_after(value: unknown): Reply return run(value, "feed_read_after") end
function M.list(value: unknown): Reply return run(value, "list") end
function M.reconcile(value: unknown): Reply return run(value, "reconcile") end
function M.capabilities(): Reply
    return M.reply(success({
        contract_version = lifecycle.VERSION, effect_states = lifecycle.EFFECT_STATES, grant_states = lifecycle.GRANT_STATES, states = M.STATES, request_kinds = M.REQUEST_KINDS, decisions = M.DECISIONS, proposal_kinds = M.PROPOSAL_KINDS,
        bounds = {max_pending_per_requester = M.MAX_PENDING, max_proposal_bytes = M.MAX_PROPOSAL_BYTES, max_schema_bytes = M.MAX_SCHEMA_BYTES,
            max_inbox_page = M.MAX_INBOX, max_list = M.MAX_LIST, default_ttl_ms = M.DEFAULT_TTL_MS},
        expiry = "owner_reconcile", retention_ms = M.RETENTION_MS, dedupe_horizon = "retention_after_expiry", projection = "thread_outbox_at_least_once",
        events = "durable_cursor_at_least_once_until_acknowledged", notifications = "durable_without_thread", effect_routing = "registry_meta", consumption = "effect_owner_single_effect_key", authority = "incarnation_per_authority_start", revalidation = "effect_owner_under_current_incarnation",
    }, false))
end
return M

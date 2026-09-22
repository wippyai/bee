-- MIT. The approval owner: durable requests bound to an exact proposal
-- digest under a host-selected approver policy, a thread binding authorized
-- when the request is made, decisions committed by compare-and-set together
-- with their thread projection outbox row, expiry enforced by the owner, and
-- consumption bound by the effect owner to one effect identity under the
-- authority incarnation it observed.
local sql = require("sql")
local funcs = require("funcs")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local security = require("security")
local system = require("system")
local process = require("process")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local persist = require("persist")
local transaction = require("transaction")
local migrations = require("migrations")
local resources = require("resources")
local M = {}
M.LEDGER = {table = "bee_approval_schema_migrations", label = "approval"}
M.REQUEST = "bee.approvals.request"
M.DECIDE = "bee.approvals.decide"
M.MANAGE = "bee.approvals.manage"
M.OWN = "bee.approvals.own"
M.CONSUME = "bee.approvals.consume"
M.WORKER_NAME = "bee.approvals.outbox"
M.AUTHORITY_NAME = "bee.approvals.authority"
M.THREAD_GET = "bee.threads.service:get"
M.THREAD_READ = "bee.threads.service:read_after"
M.BINDING_PAGES = 4
M.TOPIC_WAKE = "bee.approvals.wake"
M.DEFAULT_TTL_MS = 600000
M.MAX_PENDING = 32
M.MAX_INBOX = 64
M.MAX_LIST = 64
M.MAX_PROPOSAL_BYTES = 8192
M.MAX_SCHEMA_BYTES = 4096
M.EXPIRE_BOUND = 64
M.RETENTION_MS = 604800000
M.REQUEST_KINDS = {"permission", "question"}
M.DECISIONS = {"approved", "denied"}
M.PROPOSAL_KINDS = {"operation", "attempt"}
M.STATES = {"pending", "decided", "expired", "withdrawn"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown, replayed: boolean}
type Row = {[string]: unknown}
type Result = transaction.Result
type Object = {[string]: unknown}
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
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function stamp(ms: integer): string
    return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format("2006-01-02T15:04:05.000Z07:00")
end
local function node(): string
    local id, err = system.node.id()
    if err or type(id) ~= "string" or id == "" then return "local" end
    return id
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.floor(value)
end
local function decode(encoded: unknown): unknown
    if type(encoded) ~= "string" then return nil end
    local value = json.decode(encoded)
    return value
end
local function digest_of(value: unknown): (string?, string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, nil, "digest failed" end
    return sum, encoded, nil
end
function M.open(): (sql.DB?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, resource_error or "approval database" end
    return persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
end
local function actor_id(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function wake()
    local pid, err = process.registry.lookup(M.WORKER_NAME)
    if err or not pid then return end
    process.send(tostring(pid), M.TOPIC_WAKE, {version = 1})
end
function M.reply(result: Result): Reply
    if result.ok then return {ok = true, error = nil, value = result.value, replayed = result.replayed} end
    return {ok = false, error = {code = result.code or "INTERNAL", message = result.message or "approval operation failed"}, value = result.value, replayed = false}
end
local operations: {[string]: Operation} = {}
local preparations: {[string]: Preparation} = {}
local mutating: {[string]: boolean} = {request = true, decide = true, withdraw = true, consume = true, revalidate = true, reconcile = true}
-- execute: one named operation for an actor over an explicit store. A
-- preparation runs first, outside the transaction, for checks that call
-- other authorities through the executor; the operation then runs inside
-- one transaction and the caller's scope answers every authority check.
function M.execute(db: sql.DB, actor: string, name: string, request: unknown, now: integer?, executor: funcs.Executor?): Result
    local operation = operations[name]
    if not operation then return failure("INVALID", "unknown operation " .. name) end
    local object = bounds.object(request == nil and {} or request)
    if not object then return failure("INVALID", "request must be an object") end
    local prepared: Object? = nil
    local preparation = preparations[name]
    if preparation then
        local outcome, refused = preparation(executor or funcs.new(), actor, object)
        if refused then return refused end
        prepared = outcome
    end
    local at = now or now_ms()
    if mutating[name] then
        return transaction.write(db, M.LEDGER.label, function(tx: sql.Transaction): Result
            return operation(tx, actor, object, at, prepared)
        end)
    end
    return transaction.read(db, M.LEDGER.label, function(tx: sql.Transaction): Result
        return operation(tx, actor, object, at, prepared)
    end)
end
-- Every method authenticates the caller, opens the linked owner store and
-- executes; a committed mutation wakes the outbox worker.
local function run(request: unknown, name: string): Reply
    local actor = actor_id()
    if not actor then return M.reply(failure("UNAUTHENTICATED", "no actor")) end
    local db, open_error = M.open()
    if not db then return M.reply(storage(open_error or "open approval store")) end
    local result = M.execute(db, actor, name, request, nil, nil)
    db:release()
    if mutating[name] and result.ok and not result.replayed then wake() end
    return M.reply(result)
end
function M.view(row: Row): Object
    return {approval_id = row.approval_id, owner_node = row.owner_node, owner_incarnation = row.owner_incarnation, workspace_id = row.workspace_id,
        requester_id = row.requester_id, request_kind = row.request_kind, policy = row.policy, proposal = decode(row.proposal_json), proposal_digest = row.proposal_digest,
        prompt = decode(row.prompt_json), response_schema = decode(row.response_schema_json), thread_id = row.thread_id, binding = decode(row.binding_json), revision = row.revision, state = row.state,
        decision = row.decision, decider_id = row.decider_id, decided_at = row.decided_at, response = decode(row.response_json), validated_incarnation = row.validated_incarnation,
        validated_by = row.validated_by, validated_at = row.validated_at, consumer_id = row.consumer_id, consumed_effect = row.consumed_effect,
        consumed_at = row.consumed_at, expires_at = row.expires_at, created_at = row.created_at, updated_at = row.updated_at}
end
local function load(tx: sql.Transaction, approval_id: string): (Row?, string?)
    local rows, err = tx:query("SELECT * FROM bee_approval_requests WHERE approval_id = ?", {approval_id})
    if err or not rows then return nil, "read approval request" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
-- The authority incarnation is established by the authority process before
-- any request is served; a missing row means no authority on this node.
local function incarnation(tx: sql.Transaction, owner: string): (integer?, Result?)
    local rows, err = tx:query("SELECT incarnation FROM bee_approval_authority WHERE owner_node = ?", {owner})
    if err or not rows then return nil, storage("read authority incarnation") end
    if #rows == 0 then return nil, failure("UNAVAILABLE", "approval authority is not established on this node") end
    return integer(rows[1].incarnation) or 1, nil
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
-- Every change is one revision: the history row, the inbox change and,
-- when the request projects onto a thread, the outbox row all commit with it.
local function record_change(tx: sql.Transaction, row: Row, revision: integer, state: string, decision: string?, actor: string, reason: string, now: integer, body: Object?): string?
    local approval_id, workspace_id = text(row.approval_id) or "", text(row.workspace_id) or ""
    local at = stamp(now)
    local _, history_error = tx:execute("INSERT INTO bee_approval_history (approval_id, revision, state, decision, actor_id, reason, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        {approval_id, revision, state, decision, actor, reason, at})
    if history_error then return "record approval history" end
    local _, inbox_error = tx:execute("INSERT INTO bee_approval_inbox (workspace_id, approval_id, revision, at) VALUES (?, ?, ?, ?)", {workspace_id, approval_id, revision, at})
    if inbox_error then return "record inbox change" end
    local thread_id = text(row.thread_id)
    if thread_id and body then
        local kind = "approval.transition"
        if state == "pending" then kind = "approval.request" end
        local encoded, encode_error = canonical.encode(body)
        if not encoded then return "encode projection: " .. tostring(encode_error) end
        local context_json: string? = nil
        local binding = bounds.object(decode(row.binding_json))
        if binding and binding.attempt_id then context_json = canonical.encode({action_id = binding.action_id, attempt_id = binding.attempt_id}) end
        local _, outbox_error = tx:execute("INSERT INTO bee_approval_outbox (event_id, approval_id, revision, thread_id, kind, body_json, context_json, attempts, next_attempt_ms, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
            {approval_id .. ":" .. tostring(revision), approval_id, revision, thread_id, kind, encoded, context_json, now, at})
        if outbox_error then return "record outbox delivery" end
    end
    return nil
end
local function transition_body(row: Row, state: string, decision: string?, decider: string?, response: unknown, reason: string): Object
    return {approval_id = row.approval_id, expected_revision = integer(row.revision) or 1, state = thread_state(state, decision), decider_id = decider, response = response, reason = reason}
end
-- Moves one pending request to a terminal state at the next revision.
local function settle(tx: sql.Transaction, row: Row, state: string, decision: string?, decider: string?, response: unknown, actor: string, reason: string, now: integer): (Row?, string?)
    local approval_id = text(row.approval_id) or ""
    local revision = (integer(row.revision) or 1) + 1
    local body = transition_body(row, state, decision, decider, response, reason)
    local change_error = record_change(tx, row, revision, state, decision, actor, reason, now, body)
    if change_error then return nil, change_error end
    local response_json: string? = nil
    if response ~= nil then response_json = canonical.encode(response) end
    local decided_at: string? = nil
    if state == "decided" then decided_at = stamp(now) end
    local _, update_error = tx:execute("UPDATE bee_approval_requests SET revision = ?, state = ?, decision = ?, decider_id = ?, decided_at = ?, response_json = ?, updated_at = ? WHERE approval_id = ? AND state = 'pending'",
        {revision, state, decision, decider, decided_at, response_json, stamp(now), approval_id})
    if update_error then return nil, "settle approval request" end
    return load(tx, approval_id)
end
-- Returns the current row and whether this call enforced the deadline.
local function expire_if_due(tx: sql.Transaction, row: Row, now: integer): (Row?, string?, boolean)
    if row.state ~= "pending" or (integer(row.expires_ms) or 0) > now then return row, nil, false end
    local settled, err = settle(tx, row, "expired", nil, nil, nil, text(row.owner_node) or "local", "deadline passed at the owner", now)
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
    local digest, encoded, digest_error = digest_of(proposal)
    if not digest or not encoded then return nil, nil, nil, "proposal: " .. tostring(digest_error) end
    if #encoded > M.MAX_PROPOSAL_BYTES then return nil, nil, nil, "proposal exceeds " .. tostring(M.MAX_PROPOSAL_BYTES) .. " bytes" end
    return proposal, digest, encoded, nil
end
local function thread_reply(executor: funcs.Executor, target: string, request: Object): (Object?, Result?)
    local reply, call_error = executor:call(target, request)
    if call_error then return nil, failure("DENIED", "thread authority refused the call") end
    local typed = bounds.object(reply)
    if not typed then return nil, failure("STORAGE", "thread authority returned no reply") end
    if typed.ok ~= true then
        local fault = bounds.object(typed.error) or {}
        return nil, failure("DENIED", "thread " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return bounds.object(typed.value) or {}, nil
end
-- The thread binding is authorized when the request is made: the requester
-- is an active owner or participant of the thread, and an attempt proposal
-- names an attempt the thread prepared under the named action. The binding
-- is persisted so delivery never depends on later membership.
local function prepare_request(executor: funcs.Executor, actor: string, object: Object): (Object?, Result?)
    if object.thread_id == nil then return nil, nil end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return nil, failure("INVALID", "thread_id is not an identifier") end
    local proposal = bounds.object(object.proposal)
    if not proposal then return nil, failure("INVALID", "proposal must be an object") end
    local summary, denied = thread_reply(executor, M.THREAD_GET, {thread_id = thread_id})
    if not summary then return nil, denied end
    local membership = bounds.object(summary.membership) or {}
    local role = text(membership.role) or ""
    if membership.active ~= true or (role ~= "owner" and role ~= "participant") then return nil, failure("DENIED", "requester is not an active owner or participant of the thread") end
    local binding: Object = {thread_id = thread_id, role = role, membership_revision = membership.revision, checked_at = stamp(now_ms())}
    if proposal.kind == "attempt" then
        local action_id, attempt_id = bounds.id(proposal.action_id), bounds.id(proposal.ref)
        if not action_id then return nil, failure("INVALID", "an attempt proposal bound to a thread names its action_id") end
        if not attempt_id then return nil, failure("INVALID", "proposal ref is not an identifier") end
        local cursor = 0
        local found: Object? = nil
        for _ = 1, M.BINDING_PAGES do
            local page, refused = thread_reply(executor, M.THREAD_READ, {thread_id = thread_id, cursor = cursor, filter = {kinds = {"attempt.prepared", "attempt.started"}, action_id = action_id}})
            if not page then return nil, refused end
            local records = page.records
            if type(records) ~= "table" then break end
            for _, raw in ipairs(records :: {unknown}) do
                local record = bounds.object(raw) or {}
                if record.attempt_id == attempt_id then found = record end
            end
            local next_cursor = integer(page.scanned_through) or integer(page.next_cursor)
            if found or not next_cursor or next_cursor <= cursor then break end
            cursor = next_cursor
        end
        if not found then return nil, failure("INVALID", "attempt " .. attempt_id .. " is not prepared under action " .. action_id .. " in the thread") end
        binding.action_id, binding.attempt_id, binding.record_id = action_id, attempt_id, found.record_id
    end
    return binding, nil
end
-- request: the authenticated operation owner asks for a decision on one
-- exact proposal under a host policy; the same key replays, a different
-- request under it conflicts.
local function op_request(tx: sql.Transaction, actor: string, object: Object, now: integer, binding: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "idempotency_key", "request_kind", "policy", "proposal", "prompt", "response_schema", "thread_id", "ttl_ms"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local workspace_id, key = bounds.id(object.workspace_id), bounds.id(object.idempotency_key)
    if not workspace_id then return failure("INVALID", "workspace_id is not an identifier") end
    if not key then return failure("INVALID", "idempotency_key is not an identifier") end
    local request_kind = bounds.member(object.request_kind, M.REQUEST_KINDS)
    if not request_kind then return failure("INVALID", "request_kind must be permission or question") end
    local policy_name = bounds.id(object.policy)
    if not policy_name then return failure("INVALID", "policy is not an identifier") end
    local proposal, proposal_digest, proposal_json, proposal_error = proposal_of(object.proposal)
    if not proposal or not proposal_digest or not proposal_json then return failure("INVALID", proposal_error or "proposal") end
    local prompt, prompt_error = values.content(object.prompt)
    if not prompt then return failure("INVALID", "prompt: " .. tostring(prompt_error)) end
    local schema = bounds.object(object.response_schema == nil and {} or object.response_schema)
    if not schema then return failure("INVALID", "response_schema must be an object") end
    local schema_json, schema_error = canonical.encode(schema)
    if not schema_json then return failure("INVALID", "response_schema: " .. tostring(schema_error)) end
    if #schema_json > M.MAX_SCHEMA_BYTES then return failure("INVALID", "response_schema exceeds " .. tostring(M.MAX_SCHEMA_BYTES) .. " bytes") end
    local thread_id, thread_valid = values.optional_id(object, "thread_id")
    if not thread_valid then return failure("INVALID", "thread_id is not an identifier") end
    if not security.can(M.REQUEST, workspace_id) then return failure("DENIED", "caller may not request approvals in workspace " .. workspace_id) end
    local policies, policies_error = resources.policies()
    if not policies then return storage(policies_error or "approver policies") end
    local policy = policies[policy_name]
    if not policy then return failure("NOT_FOUND", "approver policy " .. policy_name .. " is not configured on this host") end
    local ttl = math.min(M.DEFAULT_TTL_MS, policy.max_ttl_ms)
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 then return failure("INVALID", "ttl_ms must be a positive integer") end
        if declared > policy.max_ttl_ms then return failure("FORBIDDEN", "ttl_ms exceeds the policy ceiling of " .. tostring(policy.max_ttl_ms)) end
        ttl = declared
    end
    local request_digest, _, digest_error = digest_of(object)
    if not request_digest then return failure("INVALID", "request: " .. tostring(digest_error)) end
    local existing_rows, existing_error = tx:query("SELECT * FROM bee_approval_requests WHERE requester_id = ? AND requester_key = ?", {actor, key})
    if existing_error or not existing_rows then return storage("read approval request") end
    if #existing_rows > 0 then
        local existing = existing_rows[1] :: Row
        if existing.request_digest ~= request_digest then return failure("CONFLICT", "idempotency key was used by a different request") end
        return success(M.view(existing), true)
    end
    local pending, pending_error = tx:query("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE requester_id = ? AND state = 'pending'", {actor})
    if pending_error or not pending then return storage("count pending requests") end
    if (integer(pending[1].count) or 0) >= M.MAX_PENDING then return failure("LIMIT_EXCEEDED", "requester has " .. tostring(M.MAX_PENDING) .. " pending requests") end
    local owner = node()
    local owner_incarnation, unavailable = incarnation(tx, owner)
    if not owner_incarnation then return unavailable or storage("authority incarnation") end
    local approval_id, id_error = uuid.v7()
    if id_error or not approval_id then return storage("approval id") end
    local prompt_json = canonical.encode(prompt) or "{}"
    local binding_json: string? = nil
    if binding then binding_json = canonical.encode(binding) end
    local expires = now + ttl
    local at = stamp(now)
    local _, insert_error = tx:execute("INSERT INTO bee_approval_requests (approval_id, owner_node, owner_incarnation, workspace_id, requester_id, requester_key, request_digest, request_kind, policy, proposal_json, proposal_digest, prompt_json, response_schema_json, thread_id, binding_json, revision, state, expires_ms, expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'pending', ?, ?, ?, ?)",
        {approval_id, owner, owner_incarnation, workspace_id, actor, key, request_digest, request_kind, policy_name, proposal_json, proposal_digest, prompt_json, schema_json, thread_id, binding_json, expires, stamp(expires), at, at})
    if insert_error then return storage("record approval request") end
    local row, load_error = load(tx, approval_id)
    if not row then return storage(load_error or "read approval request") end
    local body: Object = {approval_id = approval_id, request_kind = request_kind, requester_id = actor, operation_ref = proposal.ref, prompt = prompt,
        response_schema = schema, expires_at = stamp(expires), state = "pending"}
    local change_error = record_change(tx, row, 1, "pending", nil, actor, "requested", now, body)
    if change_error then return storage(change_error) end
    return success(M.view(row), false)
end
-- decide: an eligible approver settles the pending revision for the exact
-- proposal digest; an identical retry replays, anything else conflicts.
local function op_decide(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "expected_revision", "decision", "proposal_digest", "response"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID", "approval_id is not an identifier") end
    local expected = bounds.integer(object.expected_revision)
    if not expected or expected < 1 then return failure("INVALID", "expected_revision must be a positive integer") end
    local decision = bounds.member(object.decision, M.DECISIONS)
    if not decision then return failure("INVALID", "decision must be approved or denied") end
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return failure("INVALID", "proposal_digest is required") end
    local response: unknown = nil
    if object.response ~= nil then
        local content, content_error = values.content(object.response)
        if not content then return failure("INVALID", "response: " .. tostring(content_error)) end
        response = content
    end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    local may_decide, policy_error = eligible(actor, row)
    if policy_error then return storage(policy_error) end
    if not may_decide then return failure("DENIED", "caller is not an eligible approver for this request") end
    if row.proposal_digest ~= proposal_digest then return failure("CONFLICT", "proposal digest does not match the recorded proposal", M.view(row)) end
    if row.request_kind == "question" and decision == "approved" and response == nil then return failure("INVALID", "a question needs a response to be approved") end
    local current, expire_error, expired_now = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state == "decided" then
        local wanted = ""
        if response ~= nil then wanted = canonical.encode(response) or "" end
        local same_response = wanted == (text(current.response_json) or "")
        if current.decider_id == actor and current.decision == decision and same_response then return success(M.view(current), true) end
        return failure("CONFLICT", "request was decided " .. tostring(current.decision) .. " by " .. tostring(current.decider_id), M.view(current))
    end
    if expired_now then return refusal("INVALID_STATE", "request expired at its deadline", M.view(current)) end
    if current.state ~= "pending" then return failure("INVALID_STATE", "request is " .. tostring(current.state), M.view(current)) end
    if (integer(current.revision) or 0) ~= expected then return failure("CONFLICT", "request is at revision " .. tostring(current.revision), M.view(current)) end
    local settled, settle_error = settle(tx, current, "decided", decision, actor, response, actor, "decided " .. decision, now)
    if not settled then return storage(settle_error or "settle decision") end
    return success(M.view(settled), false)
end
-- withdraw: the requester ends its own pending request; a request already
-- settled reports the outcome that actually committed.
local function op_withdraw(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID", "approval_id is not an identifier") end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    if row.requester_id ~= actor then return failure("DENIED", "only the requester withdraws a request") end
    local current, expire_error = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval request") end
    if current.state ~= "pending" then return success({withdrawn = false, request = M.view(current)}, current.state == "withdrawn") end
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
    if not approval_id then return nil, nil, failure("INVALID", "approval_id is not an identifier") end
    local proposal_digest = text(object.proposal_digest)
    if not proposal_digest then return nil, nil, failure("INVALID", "proposal_digest is required") end
    local observed = bounds.integer(object.owner_incarnation)
    if not observed or observed < 1 then return nil, nil, failure("INVALID", "owner_incarnation must be the incarnation the effect owner observed") end
    local row, load_error = load(tx, approval_id)
    if load_error then return nil, nil, storage(load_error) end
    if not row then return nil, nil, failure("NOT_FOUND", "approval request does not exist") end
    if not security.can(M.CONSUME, text(row.workspace_id) or "") then return nil, nil, failure("DENIED", "caller is not an effect owner for workspace " .. tostring(row.workspace_id)) end
    if row.proposal_digest ~= proposal_digest then return nil, nil, failure("CONFLICT", "proposal digest does not match the recorded proposal", M.view(row)) end
    local current, unavailable = incarnation(tx, text(row.owner_node) or node())
    if not current then return nil, nil, unavailable end
    if observed ~= current then
        return nil, nil, failure("REVALIDATE", "authority incarnation is " .. tostring(current) .. ", not " .. tostring(observed), {request = M.view(row), current_incarnation = current})
    end
    if row.state ~= "decided" or row.decision ~= "approved" then return nil, nil, failure("INVALID_STATE", "request is not approved", M.view(row)) end
    if (integer(row.expires_ms) or 0) <= now then return nil, nil, failure("INVALID_STATE", "approval lifetime has passed", M.view(row)) end
    return row, current, nil
end
-- revalidate: after an authority restart the effect owner re-checks the
-- decision in its own domain and records that it holds under the current
-- incarnation; consumption under that incarnation is then possible.
local function op_revalidate(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "owner_incarnation"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if (integer(row.validated_incarnation) or 0) == current then return success(M.view(row), true) end
    local _, update_error = tx:execute("UPDATE bee_approval_requests SET validated_incarnation = ?, validated_by = ?, validated_at = ?, updated_at = ? WHERE approval_id = ?",
        {current, actor, stamp(now), stamp(now), row.approval_id})
    if update_error then return storage("record validation") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(M.view(updated), false)
end
-- consume: the effect owner binds an approved decision to one effect
-- identity. A decision made under an earlier authority incarnation must
-- have been revalidated under the current one first.
local function op_consume(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id", "proposal_digest", "effect_key", "owner_incarnation"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local effect_key = bounds.id(object.effect_key)
    if not effect_key then return failure("INVALID", "effect_key is not an identifier") end
    local row, current, refused = effect_view(tx, actor, object, now)
    if not row or not current then return refused or storage("read approval request") end
    if (integer(row.owner_incarnation) or 0) ~= current and (integer(row.validated_incarnation) or 0) ~= current then
        return failure("REVALIDATE", "decision was made under authority incarnation " .. tostring(row.owner_incarnation) .. "; validate it under " .. tostring(current), {request = M.view(row), current_incarnation = current})
    end
    local consumed = text(row.consumed_effect)
    if consumed then
        if consumed == effect_key and row.consumer_id == actor then return success(M.view(row), true) end
        return failure("CONFLICT", "approval was consumed by " .. tostring(row.consumer_id) .. " for effect " .. consumed, M.view(row))
    end
    local _, update_error = tx:execute("UPDATE bee_approval_requests SET consumer_id = ?, consumed_effect = ?, consumed_at = ?, updated_at = ? WHERE approval_id = ? AND consumed_effect IS NULL",
        {actor, effect_key, stamp(now), stamp(now), row.approval_id})
    if update_error then return storage("record consumption") end
    local updated = load(tx, text(row.approval_id) or "")
    if not updated then return storage("read approval request") end
    return success(M.view(updated), false)
end
local function may_read(actor: string, row: Row): (boolean, string?)
    if row.requester_id == actor then return true, nil end
    if security.can(M.MANAGE, text(row.workspace_id) or "") then return true, nil end
    return eligible(actor, row)
end
local function op_read(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID", "approval_id is not an identifier") end
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
    if unknown_field then return failure("INVALID", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return failure("INVALID", "workspace_id is not an identifier") end
    local after = bounds.integer(object.after_seq == nil and 0 or object.after_seq)
    if not after or after < 0 then return failure("INVALID", "after_seq must be a nonnegative integer") end
    local limit = bounds.integer(object.limit == nil and M.MAX_INBOX or object.limit)
    if not limit or limit < 1 or limit > M.MAX_INBOX then return failure("INVALID", "limit must be between 1 and " .. tostring(M.MAX_INBOX)) end
    if not security.can(M.DECIDE, workspace_id) then return failure("DENIED", "caller may not read the inbox of workspace " .. workspace_id) end
    local oldest, oldest_error = tx:query("SELECT MIN(seq) AS seq FROM bee_approval_inbox WHERE workspace_id = ?", {workspace_id})
    if oldest_error or not oldest then return storage("read inbox") end
    local oldest_seq = integer(oldest[1].seq)
    if oldest_seq and after > 0 and after < oldest_seq - 1 then return failure("RESET_REQUIRED", "changes before " .. tostring(oldest_seq) .. " are compacted", {oldest_seq = oldest_seq}) end
    local rows, rows_error = tx:query("SELECT seq, approval_id, revision, at FROM bee_approval_inbox WHERE workspace_id = ? AND seq > ? ORDER BY seq LIMIT ?", {workspace_id, after, limit})
    if rows_error or not rows then return storage("read inbox") end
    local changes: {Object} = {}
    local next_seq = after
    for _, raw in ipairs(rows) do
        local change = raw :: Row
        next_seq = integer(change.seq) or next_seq
        local row = load(tx, text(change.approval_id) or "")
        if row then
            local visible, policy_error = eligible(actor, row)
            if policy_error then return storage(policy_error) end
            if visible then changes[#changes + 1] = {seq = change.seq, approval_id = change.approval_id, revision = change.revision, at = change.at, request = M.view(row)} end
        end
    end
    return success({changes = changes, next_seq = next_seq, more = #rows == limit}, false)
end
-- list: the requester's own requests, newest first, bounded.
-- A visibility-scoped snapshot/feed adapter over the approval owner's existing
-- transactional ledger. It never copies approval authority into the sync store.
local function feed_scope(actor: string, workspace: string): (string?, string?, Result?)
    local native, native_error = system.node.id()
    if native_error or not bounds.id(native) then return nil, nil, failure("UNAVAILABLE", "native node identity unavailable") end
    if not security.can(M.DECIDE, workspace) then return nil, nil, failure("DENIED", "caller may not read this workspace inbox") end
    local policies, policy_error = resources.policies()
    if not policies then return nil, nil, storage(policy_error or "read approver policies") end
    local encoded, encode_error = canonical.encode({actor = actor, definition_id = authenticated_definition(actor),
        workspace = workspace, policies = policies})
    if not encoded then return nil, nil, storage(encode_error or "encode approval visibility") end
    local scope, scope_error = hash.sha256(encoded)
    local feed, feed_error = hash.sha256(workspace)
    if not scope or scope_error or not feed or feed_error then return nil, nil, storage("measure approval visibility") end
    return "approvals." .. feed, scope, nil
end
local function inbox_head(tx: sql.Transaction): (integer?, Result?)
    local rows, err = tx:query("SELECT seq FROM sqlite_sequence WHERE name = 'bee_approval_inbox'")
    if err or not rows then return nil, storage("read inbox watermark") end
    return #rows == 0 and 0 or integer(rows[1].seq), nil
end
local function op_feed_snapshot(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "limit", "after_key", "expected_cursor", "expected_scope_revision"})
    if extra then return failure("INVALID", extra) end
    local workspace = bounds.id(object.workspace_id)
    local parsed_limit = bounds.integer(object.limit == nil and 64 or object.limit)
    local after = object.after_key == nil and "" or bounds.id(object.after_key)
    if not workspace then return failure("INVALID", "invalid snapshot workspace") end
    if not parsed_limit then return failure("INVALID", "invalid snapshot limit") end
    local fetch_limit: integer = parsed_limit + 1
    if parsed_limit < 1 or parsed_limit > 64 then return failure("INVALID", "snapshot limit must be between 1 and 64") end
    if not after then return failure("INVALID", "invalid snapshot after_key") end
    local limit: integer = parsed_limit
    local feed, scope, refused = feed_scope(actor, workspace)
    if not feed or not scope then return refused or storage("read feed scope") end
    local cursor, cursor_error = inbox_head(tx)
    if not cursor then return cursor_error or storage("read inbox watermark") end
    if object.expected_cursor ~= nil and bounds.count(object.expected_cursor) == nil then return failure("INVALID", "invalid expected_cursor") end
    if object.expected_scope_revision ~= nil and (type(object.expected_scope_revision) ~= "string" or
        #object.expected_scope_revision ~= 64 or not object.expected_scope_revision:match("^[0-9a-f]+$")) then
        return failure("INVALID", "invalid expected_scope_revision")
    end
    if after ~= "" and (object.expected_cursor == nil or object.expected_scope_revision == nil) then return failure("INVALID", "snapshot continuation requires cursor and scope revision") end
    if (object.expected_cursor ~= nil and object.expected_cursor ~= cursor) or
        (object.expected_scope_revision ~= nil and object.expected_scope_revision ~= scope) then
        return failure("RESET_REQUIRED", "snapshot changed; restart from its first page")
    end
    local rows, err = tx:query([[SELECT r.*, (SELECT MAX(i.seq) FROM bee_approval_inbox i WHERE i.approval_id = r.approval_id) AS last_sequence
        FROM bee_approval_requests r WHERE r.workspace_id = ? AND r.approval_id > ? ORDER BY r.approval_id LIMIT ?]], {workspace, after, fetch_limit})
    if err or not rows then return storage("read approval snapshot") end
    local items: {Object} = {}
    local next_key: string? = nil
    local page_bytes, truncated = 0, false
    for index, row in ipairs(rows) do
        if index > limit then break end
        local visible, policy_error = eligible(actor, row)
        if policy_error then return storage(policy_error) end
        if visible then
            local sequence = bounds.count(row.last_sequence)
            if not sequence then return storage("approval projection has no ledger position") end
            local item: Object = {schema = "bee.sync-projection@1", owner_id = node(), feed = feed,
                key = row.approval_id, revision = row.revision, value = M.view(row), tombstone = false,
                sequence = sequence, updated_at = row.updated_at}
            local encoded = canonical.encode(item)
            if not encoded then return storage("encode approval projection") end
            if #encoded > 196608 then return failure("CAPACITY_EXHAUSTED", "approval projection exceeds feed capacity") end
            if page_bytes + #encoded > 196608 then truncated = true; break end
            page_bytes = page_bytes + #encoded
            items[#items + 1] = item
        end
        next_key = text(row.approval_id)
    end
    local _, checked_scope, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-snapshot@1", owner_id = node(), feed = feed, cursor = cursor,
        earliest_cursor = 0, scope_revision = scope, items = items, complete = not truncated and #rows <= limit,
        next_key = (truncated or #rows > limit) and next_key or nil, reset_required = false}, false)
end
local function op_feed_read_after(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "cursor", "limit", "expected_scope_revision"})
    if extra then return failure("INVALID", extra) end
    local workspace, cursor = bounds.id(object.workspace_id), bounds.count(object.cursor)
    if not workspace or not cursor then return failure("INVALID", "invalid feed request") end
    if type(object.expected_scope_revision) ~= "string" or #object.expected_scope_revision ~= 64 or
        not object.expected_scope_revision:match("^[0-9a-f]+$") then return failure("INVALID", "invalid expected_scope_revision") end
    local feed, scope, refused = feed_scope(actor, workspace)
    if not feed or not scope then return refused or storage("read feed scope") end
    if object.expected_scope_revision ~= scope then return failure("RESET_REQUIRED", "take a snapshot of the current approval visibility") end
    local page = op_inbox(tx, actor, {workspace_id = workspace, after_seq = cursor, limit = object.limit}, now, nil)
    if not page.ok then return page end
    local value = bounds.object(page.value)
    if not value then return storage("read approval page") end
    local changes = value.changes :: {Object}
    local events: {Object} = {}
    local page_bytes, truncated = 0, false
    local next_cursor = value.next_seq
    for _, change in ipairs(changes) do
        local request = bounds.object(change.request)
        if not request then return storage("read approval change") end
        local item: Object = {schema = "bee.sync-event@1", owner_id = node(), feed = feed, sequence = change.seq,
            event_id = tostring(change.approval_id) .. "/" .. tostring(change.seq), event_type = "approval.changed",
            projection_key = change.approval_id, revision = request.revision, tombstone = false,
            payload = {schema_revision = "bee.approval-projection@1", request = request}, committed_at = change.at}
        local encoded = canonical.encode(item)
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
    if cursor > head then return failure("INVALID", "cursor is ahead of the inbox") end
    local _, checked_scope, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-page@1", owner_id = node(), feed = feed, scope_revision = scope,
        events = events, next_cursor = next_cursor, more = truncated or value.more, head_cursor = head,
        earliest_cursor = 0, reset_required = false}, false)
end
local function op_list(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "limit"})
    if unknown_field then return failure("INVALID", unknown_field) end
    local limit = bounds.integer(object.limit == nil and M.MAX_LIST or object.limit)
    if not limit or limit < 1 or limit > M.MAX_LIST then return failure("INVALID", "limit must be between 1 and " .. tostring(M.MAX_LIST)) end
    local statement = "SELECT * FROM bee_approval_requests WHERE requester_id = ? ORDER BY created_at DESC LIMIT ?"
    local params: {unknown} = {actor, limit}
    if object.workspace_id ~= nil then
        local workspace_id = bounds.id(object.workspace_id)
        if not workspace_id then return failure("INVALID", "workspace_id is not an identifier") end
        statement = "SELECT * FROM bee_approval_requests WHERE requester_id = ? AND workspace_id = ? ORDER BY created_at DESC LIMIT ?"
        params = {actor, workspace_id, limit}
    end
    local rows, err = tx:query(statement, params)
    if err or not rows then return storage("list approval requests") end
    local views: {Object} = {}
    for _, row in ipairs(rows) do views[#views + 1] = M.view(row) end
    return success({requests = views}, false)
end
-- reconcile: the owner expires every pending request past its deadline and
-- forgets requests whose lifetime ended a retention window ago and whose
-- deliveries are all acknowledged, together with their history, inbox
-- changes and deliveries. An idempotency key older than that horizon can
-- create a fresh request; that is the advertised dedupe horizon.
local function op_reconcile(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    if not security.can(M.OWN, "*") then return failure("DENIED", "caller is not the approval owner") end
    local due, due_error = tx:query("SELECT * FROM bee_approval_requests WHERE state = 'pending' AND expires_ms <= ? ORDER BY expires_ms LIMIT ?", {now, M.EXPIRE_BOUND})
    if due_error or not due then return storage("read due requests") end
    local expired = 0
    for _, raw in ipairs(due) do
        local settled, settle_error, expired_now = expire_if_due(tx, raw :: Row, now)
        if not settled then return storage(settle_error or "expire request") end
        if expired_now then expired = expired + 1 end
    end
    local horizon = now - M.RETENTION_MS
    local stale, stale_error = tx:query("SELECT approval_id FROM bee_approval_requests WHERE state <> 'pending' AND expires_ms < ? AND NOT EXISTS (SELECT 1 FROM bee_approval_outbox o WHERE o.approval_id = bee_approval_requests.approval_id AND o.acknowledged_at IS NULL) LIMIT ?", {horizon, M.EXPIRE_BOUND})
    if stale_error or not stale then return storage("read retained requests") end
    local forgotten = 0
    for _, raw in ipairs(stale) do
        local approval_id = text((raw :: Row).approval_id) or ""
        for _, statement in ipairs({"DELETE FROM bee_approval_outbox WHERE approval_id = ?", "DELETE FROM bee_approval_inbox WHERE approval_id = ?",
            "DELETE FROM bee_approval_history WHERE approval_id = ?", "DELETE FROM bee_approval_requests WHERE approval_id = ?"}) do
            local _, delete_error = tx:execute(statement, {approval_id})
            if delete_error then return storage("forget retained request") end
        end
        forgotten = forgotten + 1
    end
    return success({expired = expired, forgotten = forgotten, more = #due == M.EXPIRE_BOUND}, expired == 0 and forgotten == 0)
end
-- establish: the authority process advances the incarnation once per start,
-- before any request is served under it. Delivery ownership is separate.
function M.establish(db: sql.DB): (integer?, string?)
    local owner = node()
    local result = transaction.write(db, M.LEDGER.label, function(tx: sql.Transaction): Result
        local rows, err = tx:query("SELECT incarnation FROM bee_approval_authority WHERE owner_node = ?", {owner})
        if err or not rows then return storage("read authority incarnation") end
        local next_incarnation = 1
        if #rows > 0 then next_incarnation = (integer(rows[1].incarnation) or 0) + 1 end
        local _, write_error = tx:execute("INSERT INTO bee_approval_authority (owner_node, incarnation, established_at) VALUES (?, ?, ?) ON CONFLICT(owner_node) DO UPDATE SET incarnation = excluded.incarnation, established_at = excluded.established_at",
            {owner, next_incarnation, stamp(now_ms())})
        if write_error then return storage("establish authority incarnation") end
        return success(next_incarnation, false)
    end)
    if not result.ok then return nil, result.message end
    return integer(result.value), nil
end
function M.node(): string
    return node()
end
operations.request, operations.decide, operations.withdraw, operations.consume, operations.revalidate = op_request, op_decide, op_withdraw, op_consume, op_revalidate
operations.read, operations.inbox, operations.list, operations.reconcile = op_read, op_inbox, op_list, op_reconcile
operations.feed_snapshot, operations.feed_read_after = op_feed_snapshot, op_feed_read_after
preparations.request = prepare_request
function M.request(value: unknown): Reply return run(value, "request") end
function M.decide(value: unknown): Reply return run(value, "decide") end
function M.withdraw(value: unknown): Reply return run(value, "withdraw") end
function M.consume(value: unknown): Reply return run(value, "consume") end
function M.revalidate(value: unknown): Reply return run(value, "revalidate") end
function M.read(value: unknown): Reply return run(value, "read") end
function M.inbox(value: unknown): Reply return run(value, "inbox") end
function M.feed_snapshot(value: unknown): Reply return run(value, "feed_snapshot") end
function M.feed_read_after(value: unknown): Reply return run(value, "feed_read_after") end
function M.list(value: unknown): Reply return run(value, "list") end
function M.reconcile(value: unknown): Reply return run(value, "reconcile") end
function M.capabilities(): Reply
    return M.reply(success({
        states = M.STATES, request_kinds = M.REQUEST_KINDS, decisions = M.DECISIONS, proposal_kinds = M.PROPOSAL_KINDS,
        bounds = {max_pending_per_requester = M.MAX_PENDING, max_proposal_bytes = M.MAX_PROPOSAL_BYTES, max_schema_bytes = M.MAX_SCHEMA_BYTES,
            max_inbox_page = M.MAX_INBOX, max_list = M.MAX_LIST, default_ttl_ms = M.DEFAULT_TTL_MS},
        expiry = "owner_reconcile", retention_ms = M.RETENTION_MS, dedupe_horizon = "retention_after_expiry", projection = "thread_outbox_at_least_once",
        consumption = "effect_owner_single_effect_key", authority = "incarnation_per_authority_start", revalidation = "effect_owner_under_current_incarnation",
    }, false))
end
return M

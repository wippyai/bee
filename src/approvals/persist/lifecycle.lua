local sql = require("sql")
local json = require("json")
local hash = require("hash")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local M = {}
M.VERSION = 2
M.EFFECT_STATES = {"waiting", "authorized", "reserved", "admitted", "started", "succeeded", "failed", "canceled", "uncertain"}
M.GRANT_STATES = {"active", "revoked", "expired", "exhausted"}
type Object = {[string]: unknown}
type Contract = {value: Object, encoded: string, reviewed_digest: string, effect_admission_ms: integer}
local function execute(tx: sql.Transaction, statement: string, args: {unknown}): string?
    local _, err = tx:execute(statement, args)
    if err then return tostring(err) end
    return nil
end
function M.principal(actor: string): Object
    local current = security.actor()
    local definition: string? = nil
    if current and current:id() == actor then
        local metadata = bounds.object(current:meta())
        definition = metadata and bounds.id(metadata.definition_id) or nil
    end
    return {actor_id = actor, definition_id = definition, provenance = "authenticated_local_actor"}
end
function M.prepare(actor: string, request: Object, proposal: Object, proposal_digest: string, deadline: integer, policy: resources.Policy): (Contract?, string?)
    if request.contract_version ~= nil and request.contract_version ~= M.VERSION then return nil, "unsupported approval contract version" end
    local subject = bounds.object(request.subject == nil and {principal_id = actor} or request.subject)
    if not subject or bounds.fields(subject, {"principal_id", "audience"}) or not bounds.id(subject.principal_id) then return nil, "subject needs a principal_id and optional audience" end
    if subject.audience ~= nil and not bounds.id(subject.audience) then return nil, "subject audience is invalid" end
    local origin = bounds.object(request.origin == nil and {} or request.origin)
    if not origin or bounds.fields(origin, {"app_id", "session_id", "thread_id", "action_id", "attempt_id", "instance_id"}) then return nil, "origin is invalid" end
    for _, value in pairs(origin) do if not bounds.id(value) then return nil, "origin identifiers are invalid" end end
    local scope = bounds.object(request.scope == nil and {type = "exact", parameters = proposal} or request.scope)
    local scope_type = scope and bounds.id(scope.type) or nil
    local parameters = scope and bounds.object(scope.parameters) or nil
    if not scope or not scope_type or not parameters or bounds.fields(scope, {"type", "parameters", "adapter_version", "adapter_digest"}) then return nil, "scope needs registered type and parameters" end
    local registered, scope_error = resources.scope(scope_type)
    if not registered then return nil, scope_error end
    if scope.adapter_version ~= nil and scope.adapter_version ~= registered.version then return nil, "scope adapter version differs" end
    if scope.adapter_digest ~= nil and scope.adapter_digest ~= registered.digest then return nil, "scope adapter digest differs" end
    scope = {type = scope_type, parameters = parameters, adapter_version = registered.version, adapter_digest = registered.digest, match = "exact"}
    local evidence, evidence_error = bounds.array(request.evidence == nil and {} or request.evidence, 64)
    if not evidence then return nil, tostring(evidence_error or "evidence must be a list") end
    for _, raw in ipairs(evidence) do
        local ref = bounds.object(raw)
        local digest = ref and bounds.text(ref.digest, 64) or nil
        if not ref or bounds.fields(ref, {"ref", "digest", "kind"}) or not bounds.id(ref.ref) or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "evidence requires a reference and sha256 digest" end
        if ref.kind ~= nil and not bounds.id(ref.kind) then return nil, "evidence kind is invalid" end
    end
    local presentation = request.presentation == nil and "inbox" or bounds.member(request.presentation, {"inline", "dialog", "inbox"})
    if not presentation then return nil, "presentation must be inline, dialog or inbox" end
    local admission = request.effect_admission_ms == nil and deadline or bounds.integer(request.effect_admission_ms)
    if not admission or admission < 1 or admission > deadline then return nil, "effect_admission_ms must be an absolute deadline within the policy ceiling" end
    local continuation: Object? = nil
    if request.continuation ~= nil then
        continuation = bounds.object(request.continuation)
        local destination = continuation and bounds.id(continuation.destination) or nil
        local effect_id = continuation and bounds.id(continuation.effect_id) or nil
        local context = continuation and bounds.object(continuation.context == nil and {} or continuation.context) or nil
        if not continuation or bounds.fields(continuation, {"destination", "effect_id", "context"}) or not destination or not effect_id or not context then return nil, "continuation needs registered destination, stable effect_id and context" end
        local consumer, consumer_error = resources.consumer(destination)
        if not consumer then return nil, consumer_error end
        if consumer.operation_ref ~= proposal.ref then return nil, "effect destination does not accept this operation" end
        continuation = {destination = destination, effect_id = effect_id, context = context}
    end
    local value: Object = {requester = M.principal(actor), subject = subject, origin = origin,
        provenance = {kind = "authenticated_local", requester = actor}, action = proposal, action_digest = proposal_digest,
        proposal_revision = proposal.revision, scope = scope, evidence = evidence, presentation = presentation, continuation = continuation,
        prompt = request.prompt, response_schema = request.response_schema or {}, policy_snapshot = policy,
        policy_digest = hash.sha256(canonical.encode(policy) or ""),
        effect_admission_ms = admission, reviewed_required = request.subject ~= nil or request.scope ~= nil or request.evidence ~= nil or request.continuation ~= nil}
    local encoded, encode_error = canonical.encode(value, 32768)
    if not encoded then return nil, tostring(encode_error) end
    local reviewed, hash_error = hash.sha256(encoded)
    if not reviewed or hash_error then return nil, "reviewed digest failed" end
    return {value = value, encoded = encoded, reviewed_digest = reviewed, effect_admission_ms = admission}, nil
end
function M.attach(tx: sql.Transaction, approval_id: string, contract: Contract, at: string): string?
    local err = execute(tx, "UPDATE bee_approval_requests SET contract_version = ?, contract_json = ?, reviewed_digest = ?, effect_admission_ms = ? WHERE approval_id = ?",
        {M.VERSION, contract.encoded, contract.reviewed_digest, contract.effect_admission_ms, approval_id})
    if err then return err end
    local continuation = bounds.object(contract.value.continuation)
    local effect_id = continuation and bounds.id(continuation.effect_id) or approval_id
    if not continuation then
        local consumers, consumer_error = resources.consumers()
        if not consumers then return consumer_error end
        local action = bounds.object(contract.value.action)
        for _, consumer in ipairs(consumers) do
            if action and action.ref == consumer.operation_ref then
                if continuation then return "operation has multiple effect consumers; name a destination" end
                continuation = {destination = consumer.destination, context = {}}
                effect_id = (consumer.effect_prefix or "") .. approval_id
            end
        end
    end
    local context = canonical.encode(continuation and continuation.context or {})
    return execute(tx, "INSERT INTO bee_approval_effects (approval_id, effect_id, destination, context_json, state, updated_at) VALUES (?, ?, ?, ?, 'waiting', ?)",
        {approval_id, effect_id, continuation and continuation.destination, context, at})
end
function M.read(tx: sql.Transaction, approval_id: string): (Object?, string?)
    local rows, err = tx:query("SELECT * FROM bee_approval_effects WHERE approval_id = ?", {approval_id})
    if err or not rows or #rows ~= 1 then return nil, "read approval effect" end
    local row = bounds.object(rows[1])
    if not row then return nil, "invalid approval effect" end
    if not bounds.id(row.effect_id) or not bounds.member(row.state, M.EFFECT_STATES) or not bounds.integer(row.revision)
        or (row.destination ~= nil and not bounds.id(row.destination)) then return nil, "approval effect identity or state is corrupt" end
    local context = type(row.context_json) == "string" and json.decode(row.context_json) or nil
    if not bounds.object(context) then return nil, "approval effect context is corrupt" end
    local receipt = type(row.receipt_json) == "string" and json.decode(row.receipt_json) or nil
    return {effect_id = row.effect_id, destination = row.destination, context = context, state = row.state,
        revision = row.revision, consumer_id = row.consumer_id, owner_incarnation = row.owner_incarnation,
        receipt = receipt, updated_at = row.updated_at}, nil
end
function M.change(tx: sql.Transaction, row: Object, revision: integer, state: string, decision: string?, actor: string, reason: string, at: string): string?
    local approval_id = bounds.id(row.approval_id)
    local contract = bounds.object(row.contract)
    if not approval_id or not contract then return "approval contract is missing" end
    local effect, read_error = M.read(tx, approval_id)
    if not effect then return read_error end
    local outcome = state == "decided" and (decision == "approved" and "decided" or "denied") or state
    local event: Object = {contract_version = row.contract_version, approval_id = approval_id, owner_node = row.owner_node,
        workspace_id = row.workspace_id, revision = revision, state = state, decision = decision,
        reviewed_digest = row.reviewed_digest, effect_id = effect.effect_id, destination = effect.destination,
        requester = contract.requester, subject = contract.subject, presentation = contract.presentation}
    local body, body_error = canonical.encode(event, 16384)
    if not body then return body_error end
    local destinations: {string} = {"requester:" .. tostring(row.requester_id)}
    if state ~= "pending" and type(effect.destination) == "string" then destinations[#destinations + 1] = effect.destination end
    for _, destination in ipairs(destinations) do
        local event_id = approval_id .. ":" .. tostring(revision) .. ":" .. destination
        local err = execute(tx, "INSERT INTO bee_approval_events(event_id, approval_id, revision, kind, destination, body_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            {event_id, approval_id, revision, state == "pending" and "approval.requested" or "approval." .. outcome, destination, body, at})
        if err then return err end
    end
    if state == "pending" then return nil end
    local effect_state = decision == "approved" and "authorized" or "canceled"
    local update_error = execute(tx, "UPDATE bee_approval_effects SET state = ?, revision = revision + 1, updated_at = ? WHERE approval_id = ? AND state = 'waiting'", {effect_state, at, approval_id})
    if update_error then return update_error end
    if state ~= "decided" then return nil end
    local windows, window_error = tx:query("SELECT window_grant_id, response_json FROM bee_approval_requests WHERE approval_id = ?", {approval_id})
    if not windows or window_error then return "read decision grant terms" end
    local kind = decision == "denied" and "deny" or (row.request_kind == "question" and "answer" or (windows[1].window_grant_id ~= nil and "allow_grant" or "allow_once"))
    local decision_id = approval_id .. ":decision:" .. tostring(revision)
    local principal_json = canonical.encode(M.principal(actor))
    local decision_error = execute(tx, "INSERT INTO bee_approval_decisions (decision_id, approval_id, revision, kind, decider_json, reviewed_digest, reviewed_revision, reason, assurance_json, response_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {decision_id, approval_id, revision, kind, principal_json, row.reviewed_digest, revision - 1, reason, '{"kind":"policy_decision"}', windows[1].response_json, at})
    if decision_error or decision ~= "approved" or row.request_kind == "question" then return decision_error end
    local subject_json = canonical.encode(contract.subject)
    local scope_json = canonical.encode(contract.scope)
    return execute(tx, "INSERT INTO bee_approval_grants (grant_id, approval_id, decision_id, subject_json, scope_json, terms_json, state, revision, until_ms, created_at) VALUES (?, ?, ?, ?, ?, ?, 'active', 1, ?, ?)",
        {approval_id .. ":grant", approval_id, decision_id, subject_json, scope_json, '{"kind":"once","time_basis":"absolute"}', row.effect_admission_ms, at})
end
function M.grant_revoked(tx: sql.Transaction, approval_id: string, requester: string, revision: integer, at: string): string?
    local effect, read_error = M.read(tx, approval_id)
    if not effect then return read_error end
    local body, encode_error = canonical.encode({contract_version = M.VERSION, approval_id = approval_id,
        grant_id = approval_id .. ":grant", revision = revision, state = "revoked", effect_id = effect.effect_id,
        already_admitted = effect.consumer_id ~= nil})
    if not body then return encode_error end
    local destinations: {string} = {"requester:" .. requester}
    if type(effect.destination) == "string" then destinations[#destinations + 1] = effect.destination end
    for _, destination in ipairs(destinations) do
        local err = execute(tx, "INSERT INTO bee_approval_events(event_id, approval_id, revision, kind, destination, body_json, created_at) VALUES (?, ?, ?, 'grant.revoked', ?, ?, ?)",
            {approval_id .. ":grant-revoked:" .. tostring(revision) .. ":" .. destination, approval_id, revision, destination, body, at})
        if err then return err end
    end
    return nil
end
function M.expire_effects(tx: sql.Transaction, now: integer, at: string): (integer?, string?)
    local rows, err = tx:query([[SELECT r.approval_id, r.requester_id, r.revision, e.effect_id, e.destination
        FROM bee_approval_requests r JOIN bee_approval_effects e ON e.approval_id = r.approval_id
        WHERE r.effect_admission_ms <= ? AND e.state IN ('authorized','reserved') LIMIT 64]], {now})
    if not rows or err then return nil, "read expired effect admissions" end
    for _, row in ipairs(rows) do
        local canceled = execute(tx, "UPDATE bee_approval_effects SET state = 'canceled', revision = revision + 1, updated_at = ? WHERE approval_id = ?", {at, row.approval_id})
        if canceled then return nil, canceled end
        local expired = execute(tx, "UPDATE bee_approval_grants SET state = 'expired', revision = revision + 1 WHERE approval_id = ? AND state = 'active'", {row.approval_id})
        if expired then return nil, expired end
        local body = canonical.encode({approval_id = row.approval_id, revision = row.revision, effect_id = row.effect_id,
            state = "canceled", reason = "effect admission deadline passed"})
        local destinations: {string} = {"requester:" .. tostring(row.requester_id)}
        if type(row.destination) == "string" then destinations[#destinations + 1] = row.destination end
        for _, destination in ipairs(destinations) do
            local queued = execute(tx, "INSERT INTO bee_approval_events(event_id, approval_id, revision, kind, destination, body_json, created_at) VALUES (?, ?, ?, 'effect.canceled', ?, ?, ?)",
                {tostring(row.approval_id) .. ":admission-expired:" .. destination, row.approval_id, row.revision, destination, body, at})
            if queued then return nil, queued end
        end
    end
    return #rows, nil
end
function M.consume(tx: sql.Transaction, approval_id: string, actor: string, effect_id: string, incarnation: integer, at: string, bound: boolean): string?
    local effect, err = M.read(tx, approval_id)
    if not effect then return err end
    if bound and effect.effect_id ~= effect_id then return "registered continuation effect identity differs" end
    local update_error = execute(tx, "UPDATE bee_approval_effects SET effect_id = ?, state = 'admitted', consumer_id = ?, owner_incarnation = ?, revision = revision + 1, updated_at = ? WHERE approval_id = ? AND state IN ('authorized','reserved')", {effect_id, actor, incarnation, at, approval_id})
    if update_error then return update_error end
    return execute(tx, "UPDATE bee_approval_grants SET state = 'exhausted', used = 1, revision = revision + 1 WHERE approval_id = ? AND state = 'active'", {approval_id})
end
function M.complete(tx: sql.Transaction, approval_id: string, state: string, result_json: string, at: string): string?
    return execute(tx, "UPDATE bee_approval_effects SET state = ?, receipt_json = ?, revision = revision + 1, updated_at = ? WHERE approval_id = ?", {state, result_json, at, approval_id})
end
function M.ack_effect(tx: sql.Transaction, approval_id: string, at: string): string?
    return execute(tx, "UPDATE bee_approval_events SET acknowledged_at = COALESCE(acknowledged_at, ?) WHERE approval_id = ? AND destination IN (SELECT destination FROM bee_approval_effects WHERE approval_id = ?)", {at, approval_id, approval_id})
end
function M.records(tx: sql.Transaction, approval_id: string): (Object?, string?)
    local decisions, decision_error = tx:query("SELECT * FROM bee_approval_decisions WHERE approval_id = ? ORDER BY revision", {approval_id})
    local grants, grant_error = tx:query("SELECT * FROM bee_approval_grants WHERE approval_id = ?", {approval_id})
    if not decisions or decision_error or not grants or grant_error then return nil, "read lifecycle records" end
    return {decisions = decisions, grants = grants}, nil
end
return M

-- MIT. Requests for the approvals authority.
local sql = require("sql")
local funcs = require("funcs")
local uuid = require("uuid")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local values = require("values")
local resources = require("resources")
local store = require("store")
local runtime_lease = require("runtime_lease")
local windows = require("windows")
local grants = require("grants")
local lifecycle = require("lifecycle")
local part_authority = require("part_authority")
local part_model = require("part_model")
local part_projections = require("part_projections")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
type Row = part_model.Row
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local node = part_values.node
local integer = part_values.integer
local digest_of = part_values.digest_of
local response_schema_bytes = part_values.response_schema_bytes
local decode_row = part_records.decode_row
local load = part_records.load
local proposal_of = part_records.proposal_of
local incarnation = part_authority.incarnation
local record_change = part_projections.record_change
local settle = part_projections.settle
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
    local digest = digest_of(original, part_model.MAX_PROPOSAL_BYTES + part_model.MAX_SCHEMA_BYTES + 16384)
    return digest == row.request_digest
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
    local summary, denied = thread_reply(executor, part_model.THREAD_GET, {thread_id = thread_id})
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
        for _ = 1, part_model.BINDING_PAGES do
            local page, refused = thread_reply(executor, part_model.THREAD_READ, {thread_id = thread_id, cursor = cursor, filter = {kinds = {"attempt.prepared", "attempt.started"}, action_id = action_id}})
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
    local request_kind = bounds.member(object.request_kind, part_model.REQUEST_KINDS)
    if not request_kind then return failure("INVALID_ARGUMENT", "request_kind must be permission or question") end
    local policy_name = bounds.id(object.policy)
    if not policy_name then return failure("INVALID_ARGUMENT", "policy is not an identifier") end
    local proposal, proposal_digest, proposal_json, proposal_error = proposal_of(object.proposal)
    if not proposal or not proposal_digest or not proposal_json then return failure("INVALID_ARGUMENT", proposal_error or "proposal") end
    if policy_name == "local-confirmation" and proposal.ref ~= "bee.approvals:confirmation" then
        return failure("FORBIDDEN", "local confirmation policy only records instance-bound gestures")
    end
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
    if not security.can(part_model.REQUEST, workspace_id) then return failure("DENIED", "caller may not request approvals in workspace " .. workspace_id) end
    local policies, policies_error = resources.policies()
    if not policies then return storage(policies_error or "approver policies") end
    local policy = policies[policy_name]
    if not policy then return failure("NOT_FOUND", "approver policy " .. policy_name .. " is not configured on this host") end
    local ttl = math.min(policy.request_ttl_ms or part_model.DEFAULT_TTL_MS, policy.max_ttl_ms)
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 then return failure("INVALID_ARGUMENT", "ttl_ms must be a positive integer") end
        if declared > policy.max_ttl_ms then return failure("FORBIDDEN", "ttl_ms exceeds the policy ceiling of " .. tostring(policy.max_ttl_ms)) end
        ttl = declared
    end
    local contract, contract_error = lifecycle.prepare(actor, object, proposal, proposal_digest, now + policy.max_ttl_ms, policy)
    if not contract then return failure("INVALID_ARGUMENT", contract_error or "approval contract") end
    local request_digest, _, digest_error = digest_of(object, part_model.MAX_PROPOSAL_BYTES + part_model.MAX_SCHEMA_BYTES + 16384)
    if not request_digest then return failure("INVALID_ARGUMENT", "request: " .. tostring(digest_error)) end
    local existing_rows, existing_error = store.request_by_key(tx, actor, key)
    if existing_error or not existing_rows then return storage("read approval request") end
    if #existing_rows > 0 then
        local existing, decode_error = decode_row(existing_rows[1], tx)
        if not existing then return storage("decode existing approval request: " .. tostring(decode_error)) end
        if existing.request_digest ~= request_digest and not legacy_replay(object, existing, contract.value) then
            return failure("CONFLICT", "idempotency key was used by a different request")
        end
        return success(part_records.view(existing), true)
    end
    local origin = bounds.object(contract.value.origin)
    local instance = origin and bounds.id(origin.instance_id)
    if instance then
        local closed, closed_error = tx:query("SELECT instance_id FROM bee_approval_closed_origins WHERE requester_id = ? AND instance_id = ?", {actor, instance})
        if closed_error or not closed then return storage("read closed approval origin") end
        if #closed > 0 then return failure("INVALID_STATE", "approval origin is closed") end
    end
    local pending_count_value, pending_error = store.pending_count(tx, actor)
    if pending_error then return storage("count pending requests") end
    local pending_count = integer(pending_count_value)
    if not pending_count or pending_count < 0 then return storage("pending request count is corrupt") end
    if pending_count >= part_model.MAX_PENDING then return failure("LIMIT_EXCEEDED", "requester has " .. tostring(part_model.MAX_PENDING) .. " pending requests") end
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
                return success(part_records.view(settled), false)
            end
        end
    end
    return success(part_records.view(row), false)
end
M.op_request = op_request
M.prepare_request = prepare_request
M.thread_reply = thread_reply
return M

-- SPDX-License-Identifier: MIT
-- Runtime capability elevation through the existing approval owner. An
-- agent attempt asks for one host catalog capability; the person decides
-- on the catalog's own wording bound to that thread and attempt. On
-- approval the gateway consumes the decision and writes one resources
-- grant row for the authenticated thread actor. Decisions remain in the
-- approval owner; the gateway records only the resulting grant effect.
local funcs = require("funcs")
local security = require("security")
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local capability = require("capability")
local M = {}
M.ELEVATION_CALL_POLICY = "bee.gateway.security:elevation_policy"
M.REQUEST_POLICY_REF = "bee.gateway:approval_request_policy_ref"
M.CONSUME_POLICY_REF = "bee.gateway:approval_consume_policy_ref"
M.GRANT_THREAD_POLICY = "bee.security.resources:resource_grant_thread_policy"
M.CATALOG_ENTRY = "bee:capability_catalog"
M.GRANT_CALL = "bee.resources.binding:grant"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local function fail(code: string, message: string): Reply return {ok = false, value = nil, error = {code = code, message = message}} end
local function linked_policy(reference: string, description: string): (string?, string?)
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, description .. " policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local target = data and bounds.id(data.resource_ref)
    if not target then return nil, description .. " policy is not linked" end
    return target, nil
end
-- The executor runs as the bound subject in its binding's workspace under
-- the elevation call policy plus the host-linked approval policies and the
-- thread-grant policy. The scope is server-side plumbing: the approval
-- bound to this thread and attempt is the authority for every effect.
local function invoke(binding: Binding, operation: string, value: Object): Reply
    local meta: {[string]: string} = {}
    if binding.workspace_id then meta.workspace_id = binding.workspace_id end
    local actor, actor_error = security.new_actor(binding.subject, meta)
    if not actor then return fail("DENIED", tostring(actor_error)) end
    local policies: {security.Policy} = {}
    local request, request_error = linked_policy(M.REQUEST_POLICY_REF, "approval request")
    if not request then return fail("UNAVAILABLE", request_error or "approval request policy") end
    local consume, consume_error = linked_policy(M.CONSUME_POLICY_REF, "approval consume")
    if not consume then return fail("UNAVAILABLE", consume_error or "approval consume policy") end
    for _, id in ipairs({M.ELEVATION_CALL_POLICY, request, consume, M.GRANT_THREAD_POLICY}) do
        local policy, policy_error = security.policy(id)
        if not policy then return fail("UNAVAILABLE", tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local acted, actor_failure = funcs.new():with_actor(actor)
    if not acted then return fail("DENIED", tostring(actor_failure)) end
    local scoped, scope_error = acted:with_scope(security.new_scope(policies))
    if not scoped then return fail("DENIED", tostring(scope_error)) end
    local target = operation == "grant" and M.GRANT_CALL or "bee.approvals.binding:" .. operation
    local raw, call_error = scoped:call(target, value)
    if call_error then return fail("UNAVAILABLE", tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply or type(reply.ok) ~= "boolean" then return fail("UNAVAILABLE", "invalid approval reply") end
    if reply.ok then return {ok = true, value = reply.value} end
    local fault = bounds.object(reply.error)
    local code = fault and bounds.id(fault.code)
    local message = fault and bounds.text(fault.message, 4096)
    if not code or not message then return fail("UNAVAILABLE", "invalid approval failure") end
    return {ok = false, value = reply.value, error = {code = code, message = message}}
end
local function catalog_entry(): (unknown?, Reply?)
    local entry, entry_error = registry.get(M.CATALOG_ENTRY)
    if entry_error or not entry then return nil, fail("UNAVAILABLE", "host capability catalog is unavailable") end
    return entry, nil
end
local function measured(entry: unknown, binding: Binding, raw: unknown): (capability.Request?, Reply?)
    local request, request_error = capability.request(entry, {thread_id = binding.thread_id,
        attempt_id = binding.attempt_id, action_id = binding.action_id}, raw)
    if not request then return nil, fail("INVALID", request_error or "invalid capability request") end
    return request, nil
end
-- request: measure the capability under the asking thread and attempt, then
-- ask for a decision on the catalog-worded proposal. The deterministic
-- request key makes a retry replay the same approval instead of asking
-- the person twice.
function M.request(binding: Binding, policy_name: string, raw: unknown): Reply
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", "this binding names no workspace to elevate a capability in") end
    local entry, entry_error = catalog_entry()
    if not entry then return entry_error :: Reply end
    local request, measure_error = measured(entry, binding, raw)
    if not request then return measure_error :: Reply end
    return invoke(binding, "request", {workspace_id = workspace_id, idempotency_key = "capability:" .. capability.request_key(request),
        request_kind = "permission", policy = policy_name, proposal = capability.proposal(request),
        prompt = {text = capability.wording(request)}, thread_id = binding.thread_id})
end
-- Re-read the authoritative decision; the agent never supplies parameters,
-- digests or wording. The stored proposal is re-measured against the
-- current catalog, so a narrowed template refuses before any grant row is
-- written.
local function verified(binding: Binding, policy_name: string, entry: unknown, view: Object): (capability.Request?, string?, Reply?)
    local stored = bounds.object(view.proposal)
    local payload = stored and bounds.object(stored.payload) or nil
    local approval_id = bounds.id(view.approval_id)
    if not stored or not payload or not approval_id then return nil, nil, fail("DENIED", "approval carries no capability proposal") end
    if view.requester_id ~= binding.subject or view.thread_id ~= binding.thread_id then
        return nil, nil, fail("DENIED", "approval does not belong to this agent and thread")
    end
    local workspace = binding.workspace_id
    if not workspace or view.workspace_id ~= workspace or view.policy ~= policy_name then
        return nil, nil, fail("DENIED", "approval does not belong to this workspace and approval policy")
    end
    if payload.attempt_id ~= binding.attempt_id or payload.action_id ~= binding.action_id then
        return nil, nil, fail("DENIED", "approval does not belong to this thread and attempt")
    end
    local request, measure_error = capability.request(entry,
        {thread_id = binding.thread_id, attempt_id = binding.attempt_id, action_id = binding.action_id},
        {capability = payload.capability, parameters = payload.parameters, ttl_ms = payload.ttl_ms})
    if not request then return nil, nil, fail("DENIED", measure_error or "approved capability is no longer measurable") end
    local encoded, encode_error = canonical.encode(capability.proposal(request))
    if not encoded then return nil, nil, fail("INVALID", tostring(encode_error)) end
    local expected, digest_error = hash.sha256(encoded)
    if not expected then return nil, nil, fail("INVALID", tostring(digest_error)) end
    if view.proposal_digest ~= expected then
        return nil, nil, fail("DENIED", "approval proposal differs from the requested capability")
    end
    local approval = {approval_id = approval_id, proposal_digest = payload.proposal_digest,
        thread_id = binding.thread_id, attempt_id = binding.attempt_id, capability = request.capability,
        template_revision = request.template_revision, parameters_digest = request.parameters_digest}
    local consistent, consumption_error = capability.check_consumption(request, approval)
    if not consistent then return nil, nil, fail("DENIED", consumption_error or "approval does not belong to this thread and attempt") end
    return request, expected, nil
end
local function consume(binding: Binding, approval_id: string, expected: string, incarnation_raw: unknown): Reply
    local incarnation = bounds.count(incarnation_raw)
    if not incarnation or incarnation == 0 then return fail("UNAVAILABLE", "approval authority identity missing") end
    local effect_key = "capability:" .. approval_id
    local consumed = invoke(binding, "consume", {approval_id = approval_id, proposal_digest = expected,
        effect_key = effect_key, owner_incarnation = incarnation})
    if not consumed.ok and consumed.error and consumed.error.code == "REVALIDATE" then
        local state = bounds.object(consumed.value)
        local current = state and bounds.count(state.current_incarnation)
        if not current or current == 0 then return fail("UNAVAILABLE", "approval authority identity missing") end
        local validated = invoke(binding, "revalidate", {approval_id = approval_id, proposal_digest = expected, owner_incarnation = current})
        if not validated.ok then return validated end
        consumed = invoke(binding, "consume", {approval_id = approval_id, proposal_digest = expected,
            effect_key = effect_key, owner_incarnation = current})
    end
    return consumed
end
-- status: report the decision, and on approval consume it exactly once and
-- write the thread-actor grant row the attempt's placement resolves. A
-- replayed status replays the same grant instead of writing a second row:
-- the grant carries the deterministic effect key as its idempotency key.
function M.status(binding: Binding, policy_name: string, approval_id_raw: unknown): Reply
    local approval_id = bounds.id(approval_id_raw)
    if not approval_id then return fail("INVALID", "approval_id is required") end
    local entry, entry_error = catalog_entry()
    if not entry then return entry_error :: Reply end
    local read = invoke(binding, "read", {approval_id = approval_id})
    if not read.ok then return read end
    local view = bounds.object(read.value)
    if not view then return fail("UNAVAILABLE", "invalid approval read") end
    local request, expected, verify_error = verified(binding, policy_name, entry, view)
    if not request or not expected then return verify_error :: Reply end
    if view.state ~= "decided" or view.decision ~= "approved" then
        return {ok = true, value = {approval_id = approval_id, status = view.decision or view.state}}
    end
    local consumed = consume(binding, approval_id, expected, view.owner_incarnation)
    if not consumed.ok then return consumed end
    local write, write_error = capability.grant_write(request, binding.workspace_id, binding.subject)
    if not write then return fail("DENIED", write_error or "approved capability writes no grant") end
    local granted = invoke(binding, "grant", write)
    if not granted.ok then return granted end
    local row = bounds.object(granted.value)
    local grant_id = row and bounds.id(row.grant_id)
    if not grant_id then return fail("UNAVAILABLE", "grant write returned no grant") end
    return {ok = true, value = {approval_id = approval_id, status = "granted", grant_id = grant_id,
        expires_at = row.expires_at, authorization_epoch = row.authorization_epoch}}
end
return M

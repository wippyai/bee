-- SPDX-License-Identifier: MIT
-- Runtime capability elevation through the existing approval owner. An
-- agent attempt asks for one host catalog capability; the person decides
-- on the catalog's own wording bound to that thread and attempt. On
-- approval the gateway consumes the decision and writes one resources
-- grant row for the authenticated thread actor. Decisions remain in the
-- approval owner; the gateway records only the resulting grant effect.
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local capability = require("capability")
local subject_call = require("subject_call")
local M = {}
M.ELEVATION_CALL_POLICY = "bee.gateway.security:elevation_policy"
M.GRANT_THREAD_POLICY = "bee.security.resources:resource_grant_thread_policy"
M.CATALOG_ENTRY = "bee:capability_catalog"
M.GRANT_CALL = "bee.resources.binding:grant"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
type Approvals = (string, Object) -> Reply
local fail = subject_call.fail
-- The approval bound to this thread and attempt is the authority for every
-- effect; the scope is server-side plumbing.
local function approvals(binding: Binding): Approvals
    return subject_call.approvals(binding, M.ELEVATION_CALL_POLICY, {M.GRANT_THREAD_POLICY})
end
local function grant(binding: Binding, value: Object): Reply
    local linked, link_error = subject_call.approval_policies()
    if not linked then return link_error :: Reply end
    return subject_call.call(binding, {M.ELEVATION_CALL_POLICY, linked[1], linked[2], M.GRANT_THREAD_POLICY},
        M.GRANT_CALL, value)
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
    return approvals(binding)("request", {workspace_id = workspace_id, idempotency_key = "capability:" .. capability.request_key(request),
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
-- status: report the decision, and on approval consume it exactly once and
-- write the thread-actor grant row the attempt's placement resolves. A
-- replayed status replays the same grant instead of writing a second row:
-- the grant carries the deterministic effect key as its idempotency key.
function M.status(binding: Binding, policy_name: string, approval_id_raw: unknown): Reply
    local approval_id = bounds.id(approval_id_raw)
    if not approval_id then return fail("INVALID", "approval_id is required") end
    local entry, entry_error = catalog_entry()
    if not entry then return entry_error :: Reply end
    local owner = approvals(binding)
    local read = owner("read", {approval_id = approval_id})
    if not read.ok then return read end
    local view = bounds.object(read.value)
    if not view then return fail("UNAVAILABLE", "invalid approval read") end
    local request, expected, verify_error = verified(binding, policy_name, entry, view)
    if not request or not expected then return verify_error :: Reply end
    if view.state ~= "decided" or view.decision ~= "approved" then
        return {ok = true, value = {approval_id = approval_id, status = view.decision or view.state}}
    end
    local consumed = subject_call.consume(owner, approval_id, expected, "capability:" .. approval_id, view.owner_incarnation)
    if not consumed.ok then return consumed end
    local write, write_error = capability.grant_write(request, binding.workspace_id, binding.subject)
    if not write then return fail("DENIED", write_error or "approved capability writes no grant") end
    local granted = grant(binding, write)
    if not granted.ok then return granted end
    local row = bounds.object(granted.value)
    local grant_id = row and bounds.id(row.grant_id)
    if not grant_id then return fail("UNAVAILABLE", "grant write returned no grant") end
    return {ok = true, value = {approval_id = approval_id, status = "granted", grant_id = grant_id,
        expires_at = row.expires_at, authorization_epoch = row.authorization_epoch}}
end
return M

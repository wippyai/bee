-- SPDX-License-Identifier: MIT
-- An MCP binding requests host-declared traits through the existing approval owner.
-- Decisions remain there; the gateway records only the resulting grant effect.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local capability_model = require("capability_model")
local surface = require("surface")
local subject_call = require("subject_call")
local M = {}
M.ACCESS_CALL_POLICY = "bee.gateway.security:access_call_policy"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
type Grant = {approval_id: string, proposal_digest: string, traits: {string}}
local NO_WORKSPACE = "this binding names no workspace to request MCP access in"
local fail = subject_call.fail
local function proposal(binding: Binding, configuration: surface.Surface, digest: string,
    capability: Object): Object
    return {kind = "attempt", ref = binding.attempt_id, action_id = binding.action_id, revision = capability_model.REVISION,
        payload = {binding_id = binding.binding_id, subject = binding.subject, thread_id = binding.thread_id,
            configuration_digest = digest, capability = capability, fixed_context = configuration.fixed_context}}
end
function M.request(binding: Binding, configuration: surface.Surface, digest: string, raw: unknown): Reply
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"idempotency_key", "traits", "reason"}) then return fail("INVALID", "access request needs idempotency_key, traits and reason") end
    local access = configuration.access
    if not access then return fail("DENIED", "this agent has no requestable MCP access") end
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", NO_WORKSPACE) end
    local key, reason = bounds.id(request.idempotency_key), bounds.text(request.reason, 1024)
    local traits, traits_error = bounds.ids(request.traits, true)
    if not key or not reason or #reason == 0 or not traits or #traits == 0 then return fail("INVALID", traits_error or "access request fields are invalid") end
    table.sort(traits)
    local granted, grant_error = surface.grant(configuration, traits)
    if not granted then return fail("DENIED", grant_error or "traits are not requestable") end
    local capability, capability_error = capability_model.traits(binding.binding_id, traits)
    if not capability then return fail("INVALID", capability_error or "invalid MCP capability") end
    local request_key, key_error = hash.sha256(binding.binding_id .. ":" .. key)
    if not request_key then return fail("INVALID", tostring(key_error)) end
    -- The person reads what the agent could do by the traits' titles; the
    -- trait ids stay in the proposal.
    local titles: {string} = {}
    for _, id in ipairs(traits) do
        local title = id
        for _, trait in ipairs(configuration.catalog.traits) do if trait.id == id then title = trait.title end end
        titles[#titles + 1] = title
    end
    return subject_call.approvals(binding, M.ACCESS_CALL_POLICY)("request", {workspace_id = workspace_id, idempotency_key = "mcp:" .. request_key,
        request_kind = "permission", policy = access.policy, proposal = proposal(binding, configuration, digest, capability),
        prompt = {text = "Let this agent session use " .. table.concat(titles, ", ") .. "? It asks: " .. reason}, thread_id = binding.thread_id})
end
-- Re-read the authoritative decision; the agent never supplies a proposal or digest.
function M.approved(binding: Binding, configuration: surface.Surface, digest: string, approval_id: string): (Grant?, Reply?)
    local access = configuration.access
    if not access then return nil, fail("DENIED", "this agent has no requestable MCP access") end
    local workspace_id = binding.workspace_id
    if not workspace_id then return nil, fail("DENIED", NO_WORKSPACE) end
    local approvals = subject_call.approvals(binding, M.ACCESS_CALL_POLICY)
    local reply = approvals("read", {approval_id = approval_id})
    if not reply.ok then return nil, reply end
    local view = bounds.object(reply.value)
    local approved_proposal = view and bounds.object(view.proposal)
    local payload = approved_proposal and bounds.object(approved_proposal.payload)
    local declared_capability = payload and bounds.object(payload.capability)
    local capability_scope = declared_capability and bounds.object(declared_capability.scope)
    local traits = capability_scope and bounds.ids(capability_scope.traits, true)
    if not view or not traits or not payload or payload.binding_id ~= binding.binding_id or payload.subject ~= binding.subject
        or payload.configuration_digest ~= digest or view.requester_id ~= binding.subject or view.thread_id ~= binding.thread_id
        or view.workspace_id ~= workspace_id or view.policy ~= access.policy or view.approval_id ~= approval_id then
        return nil, fail("DENIED", "approval does not belong to this agent and MCP configuration")
    end
    table.sort(traits)
    local permitted, permission_error = surface.grant(configuration, traits)
    if not permitted then return nil, fail("DENIED", permission_error or "traits are not requestable") end
    local expected_capability, capability_error = capability_model.traits(binding.binding_id, traits)
    if not expected_capability or not capability_model.contains(declared_capability, expected_capability)
        or not capability_model.contains(expected_capability, declared_capability) then
        return nil, fail("DENIED", capability_error or "approval capability differs from the requested MCP access")
    end
    local expected_json, encode_error = canonical.encode(proposal(binding, configuration, digest, expected_capability))
    if not expected_json then return nil, fail("INVALID", tostring(encode_error)) end
    local expected_digest, digest_error = hash.sha256(expected_json)
    if not expected_digest then return nil, fail("INVALID", tostring(digest_error)) end
    if view.proposal_digest ~= expected_digest then return nil, fail("DENIED", "approval proposal differs from the requested capability") end
    if view.state ~= "decided" or view.decision ~= "approved" then
        return nil, {ok = true, value = {approval_id = approval_id, status = view.decision or view.state}}
    end
    local consumed = subject_call.consume(approvals, approval_id, expected_digest, "mcp:" .. approval_id, view.owner_incarnation)
    if not consumed.ok then return nil, consumed end
    return {approval_id = approval_id, proposal_digest = expected_digest, traits = traits}, nil
end
return M

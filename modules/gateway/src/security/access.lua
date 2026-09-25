-- SPDX-License-Identifier: MIT
-- An MCP binding requests host-declared traits through the existing approval owner.
-- Decisions remain there; the gateway records only the resulting grant effect.
local funcs = require("funcs")
local security = require("security")
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local surface = require("surface")
local M = {}
M.ACCESS_CALL_POLICY = "bee.gateway.security:access_call_policy"
M.REQUEST_POLICY_REF = "bee.gateway:approval_request_policy_ref"
M.CONSUME_POLICY_REF = "bee.gateway:approval_consume_policy_ref"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
type Grant = {approval_id: string, proposal_digest: string, traits: {string}}
local NO_WORKSPACE = "this binding names no workspace to request MCP access in"
local function fail(code: string, message: string): Reply return {ok = false, error = {code = code, message = message}} end
local function linked_policy(reference: string, description: string): (string?, string?)
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, description .. " policy reference is unavailable" end
    local data = bounds.object(entry.data)
    local target = data and bounds.id(data.resource_ref)
    if not target then return nil, description .. " policy is not linked" end
    return target, nil
end
local function invoke(binding: Binding, operation: string, value: Object): Reply
    local actor, actor_error = security.new_actor(binding.subject)
    if not actor then return fail("DENIED", tostring(actor_error)) end
    local policies: {security.Policy} = {}
    local request, request_error = linked_policy(M.REQUEST_POLICY_REF, "approval request")
    if not request then return fail("UNAVAILABLE", request_error or "approval request policy") end
    local consume, consume_error = linked_policy(M.CONSUME_POLICY_REF, "approval consume")
    if not consume then return fail("UNAVAILABLE", consume_error or "approval consume policy") end
    for _, id in ipairs({M.ACCESS_CALL_POLICY, request, consume}) do
        local policy, policy_error = security.policy(id)
        if not policy then return fail("UNAVAILABLE", tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local acted, actor_failure = funcs.new():with_actor(actor)
    if not acted then return fail("DENIED", tostring(actor_failure)) end
    local scoped, scope_error = acted:with_scope(security.new_scope(policies))
    if not scoped then return fail("DENIED", tostring(scope_error)) end
    local raw, call_error = scoped:call("bee.approvals.binding:" .. operation, value)
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
local function proposal(binding: Binding, configuration: surface.Surface, digest: string, traits: {string}): Object
    return {kind = "attempt", ref = binding.attempt_id, action_id = binding.action_id, revision = "bee.mcp-access@1",
        payload = {binding_id = binding.binding_id, subject = binding.subject, thread_id = binding.thread_id,
            configuration_digest = digest, traits = traits, fixed_context = configuration.fixed_context}}
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
    local request_key, key_error = hash.sha256(binding.binding_id .. ":" .. key)
    if not request_key then return fail("INVALID", tostring(key_error)) end
    return invoke(binding, "request", {workspace_id = workspace_id, idempotency_key = "mcp:" .. request_key,
        request_kind = "permission", policy = access.policy, proposal = proposal(binding, configuration, digest, traits),
        prompt = {text = "Agent " .. binding.action_id .. " requests MCP access in " .. workspace_id .. ": " .. table.concat(traits, ", ") .. "\n" .. reason}, thread_id = binding.thread_id})
end
-- Re-read the authoritative decision; the agent never supplies a proposal or digest.
function M.approved(binding: Binding, configuration: surface.Surface, digest: string, approval_id: string): (Grant?, Reply?)
    local access = configuration.access
    if not access then return nil, fail("DENIED", "this agent has no requestable MCP access") end
    local workspace_id = binding.workspace_id
    if not workspace_id then return nil, fail("DENIED", NO_WORKSPACE) end
    local reply = invoke(binding, "read", {approval_id = approval_id})
    if not reply.ok then return nil, reply end
    local view = bounds.object(reply.value)
    local approved_proposal = view and bounds.object(view.proposal)
    local payload = approved_proposal and bounds.object(approved_proposal.payload)
    local traits = payload and bounds.ids(payload.traits, true)
    if not view or not traits or not payload or payload.binding_id ~= binding.binding_id or payload.subject ~= binding.subject
        or payload.configuration_digest ~= digest or view.requester_id ~= binding.subject or view.thread_id ~= binding.thread_id
        or view.workspace_id ~= workspace_id or view.policy ~= access.policy or view.approval_id ~= approval_id then
        return nil, fail("DENIED", "approval does not belong to this agent and MCP configuration")
    end
    table.sort(traits)
    local permitted, permission_error = surface.grant(configuration, traits)
    if not permitted then return nil, fail("DENIED", permission_error or "traits are not requestable") end
    local expected_json, encode_error = canonical.encode(proposal(binding, configuration, digest, traits))
    if not expected_json then return nil, fail("INVALID", tostring(encode_error)) end
    local expected_digest, digest_error = hash.sha256(expected_json)
    if not expected_digest then return nil, fail("INVALID", tostring(digest_error)) end
    if view.proposal_digest ~= expected_digest then return nil, fail("DENIED", "approval proposal differs from the requested capability") end
    if view.state ~= "decided" or view.decision ~= "approved" then
        return nil, {ok = true, value = {approval_id = approval_id, status = view.decision or view.state}}
    end
    local incarnation = bounds.count(view.owner_incarnation)
    if not incarnation or incarnation == 0 then return nil, fail("UNAVAILABLE", "approval authority identity missing") end
    local effect_key = "mcp:" .. approval_id
    local consumed = invoke(binding, "consume", {approval_id = approval_id, proposal_digest = expected_digest, effect_key = effect_key, owner_incarnation = incarnation})
    if not consumed.ok and consumed.error and consumed.error.code == "REVALIDATE" then
        local state = bounds.object(consumed.value)
        local current = state and bounds.count(state.current_incarnation)
        if not current or current == 0 then return nil, fail("UNAVAILABLE", "approval authority identity missing") end
        -- The exact binding and frozen configuration were checked above. A second
        -- authority restart is returned to the caller instead of looping forever.
        local validated = invoke(binding, "revalidate", {approval_id = approval_id, proposal_digest = expected_digest, owner_incarnation = current})
        if not validated.ok then return nil, validated end
        consumed = invoke(binding, "consume", {approval_id = approval_id, proposal_digest = expected_digest, effect_key = effect_key, owner_incarnation = current})
    end
    if not consumed.ok then return nil, consumed end
    return {approval_id = approval_id, proposal_digest = expected_digest, traits = traits}, nil
end
return M

-- SPDX-License-Identifier: MIT
-- Owner calls a bound subject makes through the gateway's private effect
-- paths: the call runs as the binding's subject in its workspace under an
-- explicit policy set, the host links the approval request and consume
-- policies, and an approved decision is consumed exactly once under one
-- effect key, revalidated when the approval authority restarted.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local M = {}
M.REQUEST_POLICY_REF = "bee.gateway:approval_request_policy_ref"
M.CONSUME_POLICY_REF = "bee.gateway:approval_consume_policy_ref"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
type Approvals = (string, Object) -> Reply

function M.fail(code: string, message: string): Reply return {ok = false, value = nil, error = {code = code, message = message}} end

local function linked_policy(reference: string, description: string): (string?, Reply?)
    local entry, entry_error = registry.get(reference)
    if entry_error or not entry then return nil, M.fail("UNAVAILABLE", description .. " policy reference is unavailable") end
    local data = bounds.object(entry.data)
    local target = data and bounds.id(data.resource_ref)
    if not target then return nil, M.fail("UNAVAILABLE", description .. " policy is not linked") end
    return target, nil
end

-- The host-linked approval request and consume policies, in that order.
function M.approval_policies(): ({string}?, Reply?)
    local request, request_error = linked_policy(M.REQUEST_POLICY_REF, "approval request")
    if not request then return nil, request_error end
    local consume, consume_error = linked_policy(M.CONSUME_POLICY_REF, "approval consume")
    if not consume then return nil, consume_error end
    return {request, consume}, nil
end

-- raw_call: one call as the bound subject under exactly these policies; the
-- reply object is the callee's own shape.
function M.raw_call(binding: Binding, policy_ids: {string}, target: string, value: Object): (Object?, Reply?)
    local meta: {[string]: string} = {}
    if binding.workspace_id then meta.workspace_id = binding.workspace_id end
    local actor, actor_error = security.new_actor(binding.subject, meta)
    if not actor then return nil, M.fail("DENIED", tostring(actor_error)) end
    local policies: {security.Policy} = {}
    for _, id in ipairs(policy_ids) do
        local policy, policy_error = security.policy(id)
        if not policy then return nil, M.fail("UNAVAILABLE", tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local acted, actor_failure = funcs.new():with_actor(actor)
    if not acted then return nil, M.fail("DENIED", tostring(actor_failure)) end
    local scoped, scope_error = acted:with_scope(security.new_scope(policies))
    if not scoped then return nil, M.fail("DENIED", tostring(scope_error)) end
    local raw, call_error = scoped:call(target, value)
    if call_error then return nil, M.fail("UNAVAILABLE", tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply then return nil, M.fail("UNAVAILABLE", "invalid owner reply") end
    return reply, nil
end

-- call: an owner call whose reply is {ok, value, error: {code, message}}.
function M.call(binding: Binding, policy_ids: {string}, target: string, value: Object): Reply
    local reply, failure = M.raw_call(binding, policy_ids, target, value)
    if not reply then return failure or M.fail("UNAVAILABLE", "invalid owner reply") end
    if type(reply.ok) ~= "boolean" then return M.fail("UNAVAILABLE", "invalid owner reply") end
    if reply.ok then return {ok = true, value = reply.value} end
    local fault = bounds.object(reply.error)
    local code = fault and bounds.id(fault.code)
    local message = fault and bounds.text(fault.message, 4096)
    if not code or not message then return M.fail("UNAVAILABLE", "invalid owner failure") end
    return {ok = false, value = reply.value, error = {code = code, message = message}}
end

-- approvals: one approval owner operation under the call policy plus the
-- host-linked approval policies.
function M.approvals(binding: Binding, call_policy: string, extra: {string}?): Approvals
    return function(operation: string, value: Object): Reply
        local linked, link_error = M.approval_policies()
        if not linked then return link_error :: Reply end
        local ids: {string} = {call_policy, linked[1], linked[2]}
        for _, id in ipairs(extra or {}) do ids[#ids + 1] = id end
        return M.call(binding, ids, "bee.approvals.binding:" .. operation, value)
    end
end

-- consume: bind an approved decision to one effect key. A decision observed
-- under an earlier authority incarnation is revalidated once under the
-- current one; a second restart returns to the caller.
function M.consume(approvals: Approvals, approval_id: string, proposal_digest: string, effect_key: string,
    incarnation_raw: unknown): Reply
    local incarnation = bounds.count(incarnation_raw)
    if not incarnation or incarnation == 0 then return M.fail("UNAVAILABLE", "approval authority identity missing") end
    local consumed = approvals("consume", {approval_id = approval_id, proposal_digest = proposal_digest,
        effect_key = effect_key, owner_incarnation = incarnation})
    if not consumed.ok and consumed.error and consumed.error.code == "REVALIDATE" then
        local state = bounds.object(consumed.value)
        local current = state and bounds.count(state.current_incarnation)
        if not current or current == 0 then return M.fail("UNAVAILABLE", "approval authority identity missing") end
        local validated = approvals("revalidate", {approval_id = approval_id, proposal_digest = proposal_digest,
            owner_incarnation = current})
        if not validated.ok then return validated end
        consumed = approvals("consume", {approval_id = approval_id, proposal_digest = proposal_digest,
            effect_key = effect_key, owner_incarnation = current})
    end
    return consumed
end

return M

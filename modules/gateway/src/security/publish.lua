-- SPDX-License-Identifier: MIT
-- Agent-requested Hub publication through the approval owner. The agent
-- names a package version and source; the host packs and measures the exact
-- bytes and files one approval showing module, version, digest, visibility,
-- organization and source. The agent never writes the registry or touches
-- the publishing credential: the first status poll after approval consumes
-- the decision and uploads the approved bytes through the Hub facade under
-- the publication apply policy. Later polls read the recorded receipt.
local registry = require("registry")
local funcs = require("funcs")
local bounds = require("bounds")
local publishing = require("publishing")
local subject_call = require("subject_call")
local M = {}
M.CALL_POLICY = "bee.gateway.security:publication_policy"
M.READ_POLICY = "bee.gateway.security:publication_read_policy"
M.APPLY_POLICY = "bee.gateway.security:publication_apply_policy"
M.CONFIGURATION_REF = "bee.gateway:publish_configuration_ref"
M.HUB = "bee.hub.binding:call"
type Object = {[string]: unknown}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
-- The effects one request reaches: the approval owner, and the Hub facade
-- for reads (manage false) or for the approved upload (manage true).
type Port = {approvals: (string, Object) -> Reply, hub: (Object, boolean) -> Object}
local fail = subject_call.fail

-- The host-selected approval policy publication requests are filed under;
-- an absent link fails closed.
function M.approval_policy(): (string?, Reply?)
    local reference = registry.get(M.CONFIGURATION_REF)
    local link = reference and bounds.object(reference.data) or nil
    local target = link and bounds.id(link.resource_ref) or nil
    if not target then return nil, fail("DENIED", "this host links no Hub publication configuration") end
    local entry = registry.get(target)
    local data = entry and bounds.object(entry.data) or nil
    local policy = data and bounds.id(data.approval_policy) or nil
    if not policy then return nil, fail("UNAVAILABLE", "Hub publication configuration names no approval policy") end
    return policy, nil
end

function M.port(binding: Binding): Port
    return {
        approvals = subject_call.approvals(binding, M.CALL_POLICY),
        hub = function(value: Object, manage: boolean): Object
            local policies: {string} = {M.CALL_POLICY, M.READ_POLICY}
            if manage then policies[#policies + 1] = M.APPLY_POLICY end
            local reply, failure = subject_call.raw_call(binding, policies, M.HUB, value)
            if reply then return reply end
            local fault = failure and failure.error or nil
            return {ok = false, replayed = false, code = fault and fault.code or "UNCERTAIN",
                message = fault and fault.message or "invalid Hub reply"}
        end,
    }
end

local function hub_value(port: Port, value: Object): (unknown?, Reply?)
    local reply = port.hub(value, false)
    if reply.ok ~= true then
        return nil, fail(bounds.id(reply.code) or "UNAVAILABLE", bounds.text(reply.message, 4096) or "Hub read failed")
    end
    return reply.value, nil
end

local function context(binding: Binding): {binding_id: string, thread_id: string, action_id: string, attempt_id: string}
    return {binding_id = binding.binding_id, thread_id = binding.thread_id,
        action_id = binding.action_id, attempt_id = binding.attempt_id}
end

-- request: pack and measure the source, then file one approval for the
-- exact bytes. Filing changes nothing on the Hub.
function M.request(port: Port, binding: Binding, policy: string, raw: unknown): Reply
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", "this binding names no workspace to publish from") end
    local decoded, decode_error = publishing.decode(raw)
    if not decoded then return fail("INVALID", decode_error or "invalid publication request") end
    local planned, plan_error = hub_value(port, {operation = "publish_plan",
        request = {component = decoded.component, version = decoded.version,
            visibility = decoded.visibility, source = decoded.source}})
    if plan_error then return plan_error end
    local proposal, prompt, proposal_error = publishing.proposal(planned, context(binding))
    if not proposal or not prompt then return fail("INCOMPLETE", proposal_error or "publication cannot be approved") end
    local payload = proposal.payload :: Object
    local digest = tostring(payload.plan_digest)
    local key = publishing.idempotency_key(context(binding), digest)
    if not key then return fail("INVALID", "cannot measure the publication request") end
    local filed = port.approvals("request", {workspace_id = workspace_id, idempotency_key = key,
        request_kind = "permission", policy = policy, proposal = proposal, prompt = {text = prompt},
        thread_id = binding.thread_id})
    if not filed.ok then return filed end
    local approval = bounds.object(filed.value)
    local approval_id = approval and bounds.id(approval.approval_id) or nil
    if not approval or not approval_id then return fail("UNAVAILABLE", "approval owner returned no request") end
    return {ok = true, value = {request_id = approval_id, status = "pending", action = payload.action,
        component = payload.component, version = payload.version, visibility = payload.visibility,
        digest = payload.digest, plan_digest = digest, expires_at = approval.expires_at}}
end

-- apply_approved: consumes the approved decision and uploads the approved
-- bytes through Hub. The digest comes from the recorded proposal, never
-- from the agent.
function M.apply_approved(port: Port, binding: Binding, policy: string, raw: unknown): Reply
    local value = bounds.object(raw)
    local request_id = value and bounds.id(value.request_id) or nil
    if not request_id then return fail("INVALID", "request_id is required") end
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", "this binding names no workspace to publish from") end
    local read = port.approvals("read", {approval_id = request_id})
    if not read.ok then return read end
    local view = bounds.object(read.value)
    local verified, verify_error = publishing.verify(view, binding.subject, workspace_id, policy, context(binding))
    if not view or not verified then return fail("DENIED", verify_error or "request does not belong to this agent") end
    local request = verified.request
    local function reply(outcome: publishing.Status): Reply
        return {ok = true, value = {request_id = request_id, action = request.action, component = request.component,
            version = request.version, plan_digest = verified.digest, status = outcome.status, code = outcome.code,
            message = outcome.message, state = outcome.state, replayed = outcome.replayed}}
    end
    local decision = publishing.decision(view)
    if decision.status ~= "approved" then return reply(decision) end
    local effect_key = publishing.effect_key(request_id)
    if view.effect_completed_at ~= nil or (view.consumed_effect ~= nil and view.consumed_effect ~= effect_key)
        or (view.consumer_id ~= nil and view.consumer_id ~= binding.subject) then
        return fail("DENIED", "approval was consumed by another effect owner")
    end
    if view.consumed_effect == nil and view.consumer_id == nil then
        local digest = bounds.id(view.proposal_digest)
        if not digest then return fail("UNAVAILABLE", "approval carries no proposal digest") end
        local consumed = subject_call.consume(port.approvals, request_id, digest, effect_key, view.owner_incarnation)
        if not consumed.ok then return consumed end
    end
    local effect = port.hub({operation = "publish_apply", request = {component = request.component},
        expected_digest = verified.digest}, true)
    return reply(publishing.status(effect))
end

-- status: the person's decision, or once uploaded, the recorded receipt.
-- The first poll after approval consumes the decision and uploads exactly
-- the approved bytes; later polls only read.
function M.status(port: Port, binding: Binding, policy: string, raw: unknown): Reply
    local value = bounds.object(raw)
    local request_id = value and bounds.id(value.request_id) or nil
    if not request_id then return fail("INVALID", "request_id is required") end
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", "this binding names no workspace to publish from") end
    local read = port.approvals("read", {approval_id = request_id})
    if not read.ok then return read end
    local view = bounds.object(read.value)
    local verified, verify_error = publishing.verify(view, binding.subject, workspace_id, policy, context(binding))
    if not view or not verified then return fail("DENIED", verify_error or "request does not belong to this agent") end
    local request = verified.request
    local function reply(outcome: publishing.Status): Reply
        return {ok = true, value = {request_id = request_id, action = request.action, component = request.component,
            version = request.version, plan_digest = verified.digest, status = outcome.status, code = outcome.code,
            message = outcome.message, state = outcome.state, replayed = outcome.replayed}}
    end
    local decision = publishing.decision(view)
    if decision.status ~= "approved" then return reply(decision) end
    local effect_key = publishing.effect_key(request_id)
    if view.consumed_effect ~= nil or view.consumer_id ~= nil then
        if view.consumed_effect ~= effect_key or view.consumer_id ~= binding.subject then
            return fail("DENIED", "approval was consumed by another effect owner")
        end
        return reply(publishing.status(port.hub({operation = "publish_status",
            expected_digest = verified.digest}, false)))
    end
    return M.apply_approved(port, binding, policy, {request_id = request_id})
end

return M

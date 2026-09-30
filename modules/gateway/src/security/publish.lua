-- SPDX-License-Identifier: MIT
-- Agent-requested Hub publication through the approval owner. The agent
-- names a package version and source; the worker seals the source tree into
-- one .wapp file and files one approval showing module, version, pack
-- digest, visibility, organization and source. The agent never writes the
-- registry or touches the publishing credential: once the person approves,
-- an owner worker consumes the decision and uploads the sealed file through
-- the Hub facade under the publication apply policy. Status polling only
-- reports the decision and the recorded outcome without uploading.
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

-- request: seal the source tree into one pack file, then file one approval
-- for that file's digest. Filing changes nothing on the Hub.
function M.request(port: Port, binding: Binding, policy: string, raw: unknown): Reply
    local workspace_id = binding.workspace_id
    if not workspace_id then return fail("DENIED", "this binding names no workspace to publish from") end
    local decoded, decode_error = publishing.decode(raw)
    if not decoded then return fail("INVALID", decode_error or "invalid publication request") end
    local planned, plan_error = hub_value(port, {operation = "publish_request",
        request = {component = decoded.component, version = decoded.version,
            visibility = decoded.visibility, source = decoded.source}})
    if plan_error then return plan_error end
    local staged = bounds.object(planned)
    if not staged then return fail("INCOMPLETE", "publication plan is malformed") end
    local clean = {component = staged.component, version = staged.version, digest = staged.digest,
        visibility = staged.visibility, organization = staged.organization, source = staged.source}
    if tostring(staged.plan_digest) ~= publishing.plan_digest(clean) then
        return fail("INCOMPLETE", "publication plan digest does not measure its pack")
    end
    local proposal, prompt, proposal_error = publishing.proposal(clean, context(binding))
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

-- apply_approved: the owner worker consumes the approved decision and
-- uploads the sealed file through Hub. The digest comes from the recorded
-- proposal, never from the agent. Agent status polling never calls this;
-- the publication effect worker does after the approval wakes it.
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
    if view.effect_completed_at ~= nil then
        if view.consumed_effect ~= effect_key or view.consumer_id ~= binding.subject then
            return fail("DENIED", "approval was consumed by another effect owner")
        end
        if view.effect_result == nil then return fail("UNAVAILABLE", "completed publication has no recorded Hub reply") end
        return reply(publishing.status(view.effect_result))
    end
    if view.consumed_effect == nil and view.consumer_id == nil then
        local digest = bounds.id(view.proposal_digest)
        if not digest then return fail("UNAVAILABLE", "approval carries no proposal digest") end
        local consumed = subject_call.consume(port.approvals, request_id, digest, effect_key, view.owner_incarnation)
        if not consumed.ok then return consumed end
    elseif view.consumed_effect ~= effect_key or view.consumer_id ~= binding.subject then
        return fail("DENIED", "approval was consumed by another effect owner")
    end
    local effect = port.hub({operation = "publish_apply", request = {component = request.component},
        expected_digest = verified.digest}, true)
    local outcome = publishing.status(effect)
    if outcome.status ~= "approved" then
        local digest = bounds.id(view.proposal_digest)
        if not digest then return fail("UNAVAILABLE", "approval carries no proposal digest") end
        local completed = port.approvals("complete_publication_effect", {approval_id = request_id,
            proposal_digest = digest, effect_key = effect_key, result = publishing.effect_result(effect)})
        if not completed.ok then return completed end
    end
    return reply(outcome)
end

-- status: the person's decision, or once the owner worker uploads, the
-- recorded outcome. Polling never consumes the decision and never uploads;
-- an approved request without a recorded outcome is still uploading.
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
    if view.effect_completed_at ~= nil then
        if view.consumed_effect ~= effect_key or view.consumer_id ~= binding.subject then
            return fail("DENIED", "approval was consumed by another effect owner")
        end
        if view.effect_result == nil then return fail("UNAVAILABLE", "completed publication has no recorded Hub reply") end
        return reply(publishing.status(view.effect_result))
    end
    if (view.consumed_effect ~= nil or view.consumer_id ~= nil)
        and (view.consumed_effect ~= effect_key or view.consumer_id ~= binding.subject) then
        return fail("DENIED", "approval was consumed by another effect owner")
    end
    return reply(decision)
end

-- drain_approved: finds approved Hub publication requests that have not been
-- consumed, consumes each under the asking subject's binding and uploads it
-- through Hub. The approval commit wakes the publication effect worker, so
-- no status poll is needed for an approved publication to run.
function M.drain_approved(): (integer, string?)
    local policy, policy_error = M.approval_policy()
    if not policy then return 0, policy_error and policy_error.error.message or "publication policy unavailable" end
    local raw, call_error = funcs.new():call("bee.approvals.binding:publication_effects", {limit = 16})
    if call_error then return 0, tostring(call_error) end
    local listed = bounds.object(raw)
    local queue = listed and bounds.object(listed.value) or nil
    if not listed or listed.ok ~= true or not queue or type(queue.effects) ~= "table" then
        return 0, "approval owner returned no publication effect queue"
    end
    local count = 0
    local retry_error: string? = nil
    for _, raw_view in ipairs(queue.effects :: {unknown}) do
        local view = bounds.object(raw_view)
        local approval_id = view and bounds.id(view.approval_id) or nil
        local proposal = view and bounds.object(view.proposal) or nil
        local payload = proposal and bounds.object(proposal.payload) or nil
        local binding_id = payload and bounds.id(payload.binding_id) or nil
        if approval_id and view.policy == policy and proposal and proposal.ref == publishing.REF and payload and binding_id then
            local raw_resolved, resolve_error = funcs.new():call("bee.gateway.binding:effect_binding",
                {binding_id = binding_id, tools = {"publish_request"}})
            if resolve_error then return count, tostring(resolve_error) end
            local resolved_reply = not resolve_error and bounds.object(raw_resolved) or nil
            local resolved = resolved_reply and resolved_reply.ok == true and bounds.object(resolved_reply.value) or nil
            local workspace_id = resolved and bounds.id(resolved.workspace_id) or nil
            local requester_id = view.requester_id
            if resolved and workspace_id and requester_id == resolved.subject and view.workspace_id == workspace_id
                and view.thread_id == resolved.thread_id and payload.binding_id == resolved.binding_id
                and payload.thread_id == resolved.thread_id and payload.action_id == resolved.action_id
                and payload.attempt_id == resolved.attempt_id then
                local binding: Binding = {binding_id = binding_id, subject = tostring(resolved.subject),
                    action_id = tostring(resolved.action_id), attempt_id = tostring(resolved.attempt_id),
                    thread_id = tostring(resolved.thread_id), workspace_id = workspace_id}
                local applied = M.apply_approved(M.port(binding), binding, policy, {request_id = approval_id})
                if applied.ok then count = count + 1 end
                if not applied.ok then
                    local fault = applied.error
                    retry_error = fault and (fault.code .. ": " .. fault.message) or "publication effect remains pending"
                end
            else
                retry_error = "approved publication binding is not available"
            end
        end
    end
    return count, retry_error
end

return M

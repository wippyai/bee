-- MIT. Exact bridge from a selected destination plan to the existing local
-- Approvals owner. It neither decides a request nor applies an overlay.
local canonical = require("canonical")
local bounds = require("bounds")

local M = {}
local REQUEST = "bee.approvals.binding:request"
local CONSUME = "bee.approvals.binding:consume"
local REVALIDATE = "bee.approvals.binding:revalidate"

type Object = {[string]: unknown}
type Executor = {call: (Executor, string, unknown) -> (unknown?, unknown?)}
type Fault = {code: string, message: string, value: Object?}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function reply(value: unknown, err: unknown): (Object?, string?)
    if err then return nil, tostring(err) end
    local envelope = object(value)
    if not envelope then return nil, "approval owner returned a malformed reply" end
    if envelope.ok ~= true then
        local fault = object(envelope.error) or {}
        return nil, tostring(fault.code or "UNAVAILABLE") .. ": " .. tostring(fault.message or "approval owner refused the request")
    end
    local result = object(envelope.value)
    if not result then return nil, "approval owner returned no request" end
    return result, nil
end

local function typed_reply(value: unknown, err: unknown): (Object?, Fault?)
    if err then return nil, {code = "UNAVAILABLE", message = tostring(err), value = nil} end
    local envelope = object(value)
    if not envelope then return nil, {code = "UNAVAILABLE", message = "approval owner returned a malformed reply", value = nil} end
    if envelope.ok ~= true then
        local fault = object(envelope.error) or {}
        return nil, {code = tostring(fault.code or "UNAVAILABLE"),
            message = tostring(fault.message or "approval owner refused the request"),
            value = object(envelope.value)}
    end
    local result = object(envelope.value)
    if not result then return nil, {code = "UNAVAILABLE", message = "approval owner returned no request", value = nil} end
    return result, nil
end

local function hex(value: unknown): string?
    local measured = bounds.text(value, 64)
    if not measured or #measured ~= 64 or not measured:match("^[0-9a-f]+$") then return nil end
    return measured
end

local function plan(value: unknown): (Object?, string?)
    local item = object(value)
    if not item then return nil, "governance plan is not an object" end
    local workspace = bounds.id(item.workspace_id)
    local source_node, source_workspace = bounds.id(item.source_node), bounds.id(item.source_workspace)
    local version, revision = bounds.id(item.version), bounds.count(item.revision)
    local plan_digest = bounds.text(item.plan_digest, 64)
    local artifact_digest = bounds.text(item.artifact_digest, 64)
    local preflight_digest = bounds.text(item.preflight_digest, 64)
    if not workspace or not source_node or not source_workspace or not version or not revision or revision < 1
        or not plan_digest or not plan_digest:match("^[0-9a-f]+$")
        or not artifact_digest or not artifact_digest:match("^[0-9a-f]+$")
        or not preflight_digest or not preflight_digest:match("^[0-9a-f]+$") then
        return nil, "governance plan identity is malformed"
    end
    return {workspace_id = workspace, source_node = source_node, source_workspace = source_workspace,
        version = version, revision = revision, plan_digest = plan_digest,
        artifact_digest = artifact_digest, preflight_digest = preflight_digest,
        approval_id = item.approval_id, approval_proposal_digest = item.approval_proposal_digest,
        owner_incarnation = item.approval_owner_incarnation}, nil
end

function M.proposal(value: unknown): (Object?, string?)
    local item, err = plan(value)
    if not item then return nil, err end
    return {kind = "operation", ref = "bee.gov:apply", revision = item.plan_digest,
        input_digest = item.plan_digest, payload = {workspace_id = item.workspace_id,
            source_node = item.source_node, source_workspace = item.source_workspace,
            version = item.version, artifact_digest = item.artifact_digest,
            preflight_digest = item.preflight_digest}}, nil
end

function M.request(executor: Executor, value: unknown, policy_raw: unknown, key_raw: unknown): (Object?, string?)
    local item, plan_error = plan(value)
    if not item then return nil, plan_error end
    local policy, key = bounds.id(policy_raw), bounds.id(key_raw)
    if not policy or not key then return nil, "approval policy and idempotency key are required" end
    local proposal, proposal_error = M.proposal(item)
    if not proposal then return nil, proposal_error end
    local raw, call_error = executor:call(REQUEST, {workspace_id = item.workspace_id,
        idempotency_key = key, request_kind = "permission", policy = policy,
        proposal = proposal, prompt = {text = "Apply " .. tostring(item.source_workspace)
            .. " version " .. tostring(item.version) .. " to this workspace?"}})
    local approval, approval_error = reply(raw, call_error)
    if not approval then return nil, approval_error end
    local approval_id = bounds.id(approval.approval_id)
    local proposal_digest = bounds.text(approval.proposal_digest, 64)
    local incarnation = bounds.count(approval.owner_incarnation)
    local recorded = object(approval.proposal)
    local encoded_recorded = recorded and canonical.encode(recorded) or nil
    local encoded_expected = canonical.encode(proposal)
    if not approval_id or not proposal_digest or not proposal_digest:match("^[0-9a-f]+$")
        or not incarnation or incarnation < 1 or not encoded_recorded or encoded_recorded ~= encoded_expected then
        return nil, "approval owner returned a request for another proposal"
    end
    return {approval_id = approval_id, approval_proposal_digest = proposal_digest,
        approval_plan_digest = item.plan_digest, owner_incarnation = incarnation}, nil
end

local function effect(executor: Executor, method: string, value: unknown, effect_key_raw: unknown): (Object?, string?)
    local item, plan_error = plan(value)
    if not item then return nil, plan_error end
    local approval_id = bounds.id(item.approval_id)
    local proposal_digest = bounds.text(item.approval_proposal_digest, 64)
    local incarnation = bounds.count(item.owner_incarnation)
    local effect_key = bounds.id(effect_key_raw)
    if not approval_id or not proposal_digest or not proposal_digest:match("^[0-9a-f]+$")
        or not incarnation or incarnation < 1 or not effect_key then return nil, "approval effect identity is malformed" end
    local request: Object = {approval_id = approval_id, proposal_digest = proposal_digest,
        owner_incarnation = incarnation}
    if method == CONSUME then request.effect_key = effect_key end
    local raw, call_error = executor:call(method, request)
    return reply(raw, call_error)
end

function M.consume(executor: Executor, value: unknown, effect_key: unknown): (Object?, string?)
    return effect(executor, CONSUME, value, effect_key)
end

function M.revalidate(executor: Executor, value: unknown): (Object?, string?)
    return effect(executor, REVALIDATE, value, "revalidate")
end

-- Activation approvals bind the destination's freshly measured immutable
-- intent. They are separate from the earlier source-plan review approval.
local function activation(value: unknown): (Object?, string?)
    local item = object(value)
    if not item then return nil, "activation intent is not an object" end
    local result: Object = {workspace_id = bounds.id(item.workspace_id), overlay_owner = bounds.id(item.overlay_owner),
        source_node = bounds.id(item.source_node), source_workspace = bounds.id(item.source_workspace),
        version = bounds.id(item.version), authorization_digest = hex(item.authorization_digest),
        artifact_digest = hex(item.artifact_digest), resolution_digest = hex(item.resolution_digest),
        preflight_digest = hex(item.preflight_digest), effect_key = bounds.id(item.effect_key),
        approval_id = bounds.id(item.approval_id), approval_proposal_digest = hex(item.approval_proposal_digest),
        owner_incarnation = bounds.count(item.approval_owner_incarnation)}
    if not result.workspace_id or not result.overlay_owner or not result.source_node or not result.source_workspace
        or not result.version or not result.authorization_digest or not result.artifact_digest
        or not result.resolution_digest or not result.preflight_digest or not result.effect_key then
        return nil, "activation intent identity is malformed"
    end
    if item.application_admission_digest ~= nil then
        result.application_admission_digest = hex(item.application_admission_digest)
        if not result.application_admission_digest then return nil, "activation application admission digest is malformed" end
    end
    if item.grant_predecessor_digest ~= nil then
        result.grant_predecessor_digest = hex(item.grant_predecessor_digest)
        if not result.grant_predecessor_digest then return nil, "activation predecessor digest is malformed" end
    end
    return result, nil
end

local function review_lines(raw: unknown): ({string}?, string?)
    if type(raw) ~= "table" then return nil, "capability review lines are invalid" end
    local result: {string} = {}
    if #raw > 24 then return nil, "capability review exceeds its bound" end
    for index, line in ipairs(raw :: {unknown}) do
        local shown = bounds.text(line, 512)
        if not shown or shown == "" or shown:find("%c") then
            return nil, "capability review line is invalid"
        end
        result[index] = shown
    end
    return result, nil
end

function M.activation_proposal(value: unknown, review_raw: unknown?): (Object?, string?)
    local item, intent_error = activation(value)
    if not item then return nil, intent_error end
    local payload: Object = {workspace_id = item.workspace_id, overlay_owner = item.overlay_owner,
        source_node = item.source_node, source_workspace = item.source_workspace,
        version = item.version, artifact_digest = item.artifact_digest,
        resolution_digest = item.resolution_digest, preflight_digest = item.preflight_digest,
        application_admission_digest = item.application_admission_digest}
    payload.grant_predecessor_digest = item.grant_predecessor_digest
    if review_raw ~= nil then
        local review = object(review_raw)
        local resolved, resolved_error = review and review_lines(review.resolved) or nil
        local delta, delta_error = review and review_lines(review.delta) or nil
        if not resolved or not delta or type(review.requires_approval) ~= "boolean" then
            return nil, resolved_error or delta_error or "capability review is invalid"
        end
        payload.resolved_capabilities = resolved
        payload.permission_changes = delta
    end
    return {kind = "operation", ref = "bee.gov:establish-overlay",
        revision = item.authorization_digest, input_digest = item.authorization_digest,
        payload = payload}, nil
end

function M.request_activation(executor: Executor, value: unknown, policy_raw: unknown, key_raw: unknown,
    review_raw: unknown?): (Object?, string?)
    local item, intent_error = activation(value)
    if not item then return nil, intent_error end
    local policy, key = bounds.id(policy_raw), bounds.id(key_raw)
    if not policy or not key then return nil, "approval policy and idempotency key are required" end
    local proposal, proposal_error = M.activation_proposal(value, review_raw)
    if not proposal then return nil, proposal_error end
    local raw, call_error = executor:call(REQUEST, {workspace_id = item.workspace_id,
        idempotency_key = key, request_kind = "permission", policy = policy, proposal = proposal,
        prompt = {text = "Establish and recover " .. tostring(item.source_workspace)
            .. " version " .. tostring(item.version) .. " in this workspace?"}})
    local approved, approved_error = reply(raw, call_error)
    if not approved then return nil, approved_error end
    local approval_id, proposal_digest = bounds.id(approved.approval_id), hex(approved.proposal_digest)
    local incarnation = bounds.count(approved.owner_incarnation)
    local recorded = object(approved.proposal)
    local recorded_bytes = recorded and canonical.encode(recorded) or nil
    local expected_bytes = canonical.encode(proposal)
    if not approval_id or not proposal_digest or not incarnation or incarnation < 1
        or not recorded_bytes or recorded_bytes ~= expected_bytes then
        return nil, "approval owner returned a request for another activation intent"
    end
    return {approval_id = approval_id, approval_proposal_digest = proposal_digest,
        owner_incarnation = incarnation}, nil
end

local function activation_effect(executor: Executor, method: string, value: unknown,
    incarnation_raw: unknown, expected_consumer_raw: unknown?): (Object?, Fault?)
    local item, intent_error = activation(value)
    if not item then return nil, {code = "INVALID", message = tostring(intent_error), value = nil} end
    local approval_id, proposal_digest = bounds.id(item.approval_id), hex(item.approval_proposal_digest)
    local incarnation = bounds.count(incarnation_raw)
    if not approval_id or not proposal_digest or not incarnation or incarnation < 1 then
        return nil, {code = "INVALID", message = "activation approval identity is malformed", value = nil}
    end
    local request: Object = {approval_id = approval_id, proposal_digest = proposal_digest,
        owner_incarnation = incarnation}
    if method == CONSUME then request.effect_key = item.effect_key end
    local raw, call_error = executor:call(method, request)
    local result, fault = typed_reply(raw, call_error)
    if not result then return nil, fault end
    if bounds.id(result.approval_id) ~= approval_id or hex(result.proposal_digest) ~= proposal_digest then
        return nil, {code = "CONFLICT", message = "approval owner returned another activation approval", value = result}
    end
    if method == CONSUME then
        local expected_consumer = bounds.id(expected_consumer_raw)
        if not expected_consumer or bounds.id(result.consumer_id) ~= expected_consumer
            or bounds.id(result.consumed_effect) ~= item.effect_key then
            return nil, {code = "CONFLICT", message = "approval consumption receipt does not match the activation effect", value = result}
        end
    elseif bounds.count(result.validated_incarnation) ~= incarnation then
        return nil, {code = "CONFLICT", message = "approval revalidation did not bind the requested incarnation", value = result}
    end
    return result, nil
end

function M.consume_activation(executor: Executor, value: unknown, expected_consumer: unknown,
    current_incarnation: unknown?): (Object?, Fault?)
    local item, intent_error = activation(value)
    if not item then return nil, {code = "INVALID", message = tostring(intent_error), value = nil} end
    return activation_effect(executor, CONSUME, value, current_incarnation or item.owner_incarnation, expected_consumer)
end

function M.revalidate_activation(executor: Executor, value: unknown, current_incarnation: unknown): (Object?, Fault?)
    return activation_effect(executor, REVALIDATE, value, current_incarnation, nil)
end

return M

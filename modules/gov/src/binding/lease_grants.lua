-- MIT. Lease grant flow over the Approvals owner: a proposal is an ordinary
-- approval whose payload commits the whole lease, and a grant consumes that
-- exact decided approval once before the lease is stored.
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local uuid = require("uuid")
local hash = require("hash")
local capability_model = require("capability_model")
local lease_model = require("lease_model")
local lease_store = require("lease_store")

local M = {}
M.PROPOSAL = "bee.gov:grant-lease"
type Object = {[string]: unknown}
type Result = transaction.Result
type Executor = {call: (Executor, string, unknown) -> (unknown?, unknown?)}
type Profile = {overlay_owner: string, approval_policy: string, source_workspace: string}

local LEASE_PROPOSAL = M.PROPOSAL
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

function M.propose(executor: Executor, vocabulary: capability_model.Vocabulary, installed: {capability_model.Grant},
    chosen: Profile, workspace_id: string, request: Object, key: string): Result
    local requested = bounds.dense_list(request.extras == nil and {} or request.extras, 8, "lease extras")
    local ttl, max, bound_error = lease_model.bounded(request.ttl_seconds, request.max_applies)
    if not requested or bound_error then return failure("INVALID", bound_error or "lease extras are invalid") end
    -- Extras are capability requests the host resolves through its own
    -- catalog; a caller never supplies a resolved grant.
    local extras: {capability_model.Grant} = {}
    for _, raw in ipairs(requested) do
        local item = bounds.object(raw)
        local capability = item and bounds.id(item.capability) or nil
        if not item or not capability or bounds.fields(item, {"capability", "parameters"}) then
            return failure("INVALID", "a lease extra names a capability and its parameters")
        end
        local resolved, resolve_error = capability_model.resolve(vocabulary, capability, item.parameters == nil and {} or item.parameters)
        if not resolved then return failure("INVALID", resolve_error or "lease extra does not resolve") end
        for _, grant in ipairs(resolved) do extras[#extras + 1] = grant end
    end
    local envelope, envelope_error = lease_model.envelope(vocabulary, installed, extras)
    if not envelope then return failure("INVALID", envelope_error or "lease envelope is invalid") end
    local lines, render_error = capability_model.render(vocabulary, envelope)
    if not lines then return failure("INVALID", render_error or "lease envelope cannot be rendered") end
    local envelope_digest = lease_model.envelope_digest(envelope)
    local proposal_seed = canonical.encode({target = chosen.overlay_owner, envelope = envelope_digest, ttl = ttl, max = max})
    local seed_digest = proposal_seed and hash.sha256(proposal_seed)
    if not envelope_digest or not seed_digest then return failure("INTERNAL", "measure lease proposal") end
    local raw, call_error = executor:call("bee.approvals.binding:request", {workspace_id = workspace_id,
        idempotency_key = key, request_kind = "permission", policy = chosen.approval_policy,
        proposal = {kind = "operation", ref = LEASE_PROPOSAL, revision = seed_digest, input_digest = seed_digest,
            payload = {workspace_id = workspace_id, target = chosen.overlay_owner, operation = "grant lease",
                source_node = request.source_node, source_workspace = chosen.source_workspace, envelope = envelope,
                ttl_seconds = ttl, max_applies = max, resolved_capabilities = lines}},
        prompt = {text = "Let " .. chosen.source_workspace .. " apply changes inside this envelope without asking again?"}})
    local reply = bounds.object(raw)
    if call_error or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error) or nil
        return failure("APPROVAL", tostring(call_error or (fault and fault.message) or "approval owner refused the lease request"))
    end
    return transaction.success({approval = reply.value, lines = lines}, false)
end

function M.grant(executor: Executor, lease_handle: lease_store.Store, vocabulary: capability_model.Vocabulary,
    chosen: Profile, workspace_id: string, actor_id: string, request: Object, key: string): Result
    local approval_id = bounds.id(request.approval_id)
    if not approval_id then return failure("INVALID", "approval_id is required") end
    local read_raw, read_error = executor:call("bee.approvals.binding:read", {approval_id = approval_id})
    local read_reply = bounds.object(read_raw)
    local approval = read_reply and read_reply.ok == true and bounds.object(read_reply.value) or nil
    if read_error or not approval then return failure("APPROVAL", "lease approval cannot be read") end
    local proposal = bounds.object(approval.proposal)
    local payload = proposal and bounds.object(proposal.payload) or nil
    local proposal_digest = bounds.text(approval.proposal_digest, 64)
    local incarnation = bounds.count(approval.owner_incarnation)
    if approval.state ~= "decided" or approval.decision ~= "approved" or approval.policy ~= chosen.approval_policy
        or approval.workspace_id ~= workspace_id or not proposal or proposal.ref ~= LEASE_PROPOSAL or not payload
        or payload.target ~= chosen.overlay_owner or payload.source_workspace ~= chosen.source_workspace or not proposal_digest or not incarnation or incarnation < 1 then
        return failure("DENIED", "approval is not a decided lease grant for this application")
    end
    local envelope = bounds.dense_list(payload.envelope, lease_model.MAX_ENVELOPE, "lease envelope")
    if not envelope then return failure("INVALID", "approved lease envelope is malformed") end
    local checked, checked_error = lease_model.envelope(vocabulary, {}, envelope :: {capability_model.Grant})
    if not checked then return failure("INVALID", checked_error or "approved lease envelope is invalid") end
    local effect_seed = hash.sha256("bee.gov.lease_grant\n" .. approval_id)
    if not effect_seed then return failure("INTERNAL", "measure lease effect") end
    local consume_raw, consume_error = executor:call("bee.approvals.binding:consume", {approval_id = approval_id,
        proposal_digest = proposal_digest, owner_incarnation = incarnation, effect_key = "lease-" .. effect_seed})
    local consume_reply = bounds.object(consume_raw)
    if consume_error or not consume_reply or consume_reply.ok ~= true then
        local fault = consume_reply and bounds.object(consume_reply.error) or nil
        return failure("APPROVAL", tostring(consume_error or (fault and fault.message) or "lease approval cannot be consumed"))
    end
    local lease_id = uuid.v7()
    if not lease_id then return failure("INTERNAL", "lease id") end
    return lease_store.call(lease_handle, actor_id, {operation = "grant", idempotency_key = key, lease_id = lease_id,
        target = chosen.overlay_owner, envelope = checked, source_approval_id = approval_id,
        source_approval_proposal_digest = proposal_digest, source_approval_owner_incarnation = incarnation,
        granted_by = tostring(approval.decider_id or actor_id), ttl_seconds = payload.ttl_seconds,
        max_applies = payload.max_applies})
end

return M

-- MIT. Lease grant flow over the Approvals owner: a proposal is an ordinary
-- approval whose payload commits the whole lease, and a grant consumes that
-- exact decided approval once before the lease is stored.
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
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
local MAX_REVIEW_LINES = 20
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

-- A set-valued parameter arrives as text with | between members, or as a
-- list; the catalog says which parameters are sets, so one member is a
-- one-element list and a scalar stays text.
local function coerce(vocabulary: capability_model.Vocabulary, capability: string, parameters: unknown): (Object?, string?)
    local given = parameters == nil and {} or bounds.object(parameters)
    local template = capability_model.template(vocabulary, capability)
    if not given or not template then return nil, "lease extra parameters are invalid" end
    local result: Object = {}
    for name, value in pairs(given) do
        local kind = template.parameters[name]
        if kind and capability_model.collection_kind(kind) and type(value) == "string" then
            local members: {string} = {}
            for member in (value):gmatch("[^|]+") do members[#members + 1] = member end
            result[name] = members
        else
            result[name] = value
        end
    end
    return result, nil
end

local function duration_words(seconds: integer): string
    if seconds % 86400 == 0 then return tostring(seconds // 86400) .. " days" end
    if seconds % 3600 == 0 then return tostring(seconds // 3600) .. " hours" end
    if seconds % 60 == 0 then return tostring(seconds // 60) .. " minutes" end
    return tostring(seconds) .. " seconds"
end

-- The person-facing terms of a lease, from the same typed values the lease is
-- stored with: what it lasts, when that starts, how many applies it allows and
-- for which application. The approval request's own expiry is separate.
local function terms(target: string, ttl: integer?, max: integer?): {string}
    return {"Lease for " .. target .. ": changes inside the ceiling below apply without asking again",
        ttl and ("Lasts " .. duration_words(ttl) .. ", counted from the moment it is granted, not from this request's expiry") or "No expiry",
        max and ("At most " .. tostring(max) .. " applies") or "No limit on applies"}
end
M.terms = terms

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
        local coerced, coerce_error = coerce(vocabulary, capability, item.parameters)
        if not coerced then return failure("INVALID", coerce_error or "lease extra parameters are invalid") end
        local resolved, resolve_error = capability_model.resolve(vocabulary, capability, coerced)
        if not resolved then return failure("INVALID", resolve_error or "lease extra does not resolve") end
        for _, grant in ipairs(resolved) do extras[#extras + 1] = grant end
    end
    local envelope, envelope_error = lease_model.envelope(vocabulary, installed, extras)
    if not envelope then return failure("INVALID", envelope_error or "lease envelope is invalid") end
    local lines, render_error = capability_model.render(vocabulary, envelope)
    if not lines then return failure("INVALID", render_error or "lease envelope cannot be rendered") end
    if #envelope > lease_model.MAX_REVIEWED or #lines > MAX_REVIEW_LINES then
        return failure("INVALID", "a lease ceiling shows at most " .. tostring(lease_model.MAX_REVIEWED) .. " grants for review")
    end
    local envelope_digest = lease_model.envelope_digest(envelope)
    local proposal_seed = canonical.encode({target = chosen.overlay_owner, envelope = envelope_digest, ttl = ttl, max = max})
    local seed_digest = proposal_seed and hash.sha256(proposal_seed)
    if not envelope_digest or not seed_digest then return failure("INTERNAL", "measure lease proposal") end
    local raw, call_error = executor:call("bee.approvals.binding:request", {workspace_id = workspace_id,
        idempotency_key = key, request_kind = "permission", policy = chosen.approval_policy,
        proposal = {kind = "operation", ref = LEASE_PROPOSAL, revision = seed_digest, input_digest = seed_digest,
            payload = {workspace_id = workspace_id, target = chosen.overlay_owner, operation = "grant lease",
                source_node = request.source_node, source_workspace = chosen.source_workspace, envelope = envelope,
                ttl_seconds = ttl, max_applies = max, permission_changes = terms(chosen.overlay_owner, ttl, max),
                resolved_capabilities = lines}},
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
    -- One approval grants one lease; a repeated request returns it.
    local existing = lease_store.by_approval(lease_handle, approval_id)
    if existing.ok then
        local lease = bounds.object(existing.value)
        if not lease or lease.target ~= chosen.overlay_owner then return failure("DENIED", "approval granted a lease for another application") end
        return transaction.success(lease, true)
    end
    if existing.code ~= "NOT_FOUND" then return existing end
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
    local envelope = capability_model.grants(payload.envelope)
    if not envelope then return failure("INVALID", "approved lease envelope is malformed") end
    local checked, checked_error = lease_model.envelope(vocabulary, {}, envelope)
    if not checked then return failure("INVALID", checked_error or "approved lease envelope is invalid") end
    local effect_seed = hash.sha256("bee.gov.lease_grant\n" .. approval_id)
    if not effect_seed then return failure("INTERNAL", "measure lease effect") end
    local consume = {approval_id = approval_id, proposal_digest = proposal_digest, owner_incarnation = incarnation,
        effect_key = "lease-" .. effect_seed}
    local consume_raw, consume_error = executor:call("bee.approvals.binding:consume", consume)
    local consume_reply = bounds.object(consume_raw)
    local fault = consume_reply and consume_reply.ok ~= true and bounds.object(consume_reply.error) or nil
    if fault and fault.code == "REVALIDATE" then
        -- The approval owner restarted since the decision. The exact proposal
        -- was just re-read and re-validated against the current catalog and
        -- policy above; the owner validates it under its current incarnation,
        -- then it is consumed under that incarnation.
        local fault_value = bounds.object(consume_reply and consume_reply.value or nil)
        local current = fault_value and bounds.count(fault_value.current_incarnation) or nil
        if not current or current < 1 then return failure("APPROVAL", "approval owner reported no current incarnation") end
        local validated_raw, validate_error = executor:call("bee.approvals.binding:revalidate", {approval_id = approval_id,
            proposal_digest = proposal_digest, owner_incarnation = current})
        local validated = bounds.object(validated_raw)
        if validate_error or not validated or validated.ok ~= true then
            local validation_fault = validated and bounds.object(validated.error) or nil
            return failure("APPROVAL", tostring(validate_error or (validation_fault and validation_fault.message) or "lease approval cannot be revalidated"))
        end
        incarnation = current
        consume.owner_incarnation = current
        consume_raw, consume_error = executor:call("bee.approvals.binding:consume", consume)
        consume_reply = bounds.object(consume_raw)
        fault = consume_reply and consume_reply.ok ~= true and bounds.object(consume_reply.error) or nil
    end
    if consume_error or not consume_reply or consume_reply.ok ~= true then
        return failure("APPROVAL", tostring(consume_error or (fault and fault.message) or "lease approval cannot be consumed"))
    end
    local lease_id = "lease-" .. effect_seed
    return lease_store.call(lease_handle, actor_id, {operation = "grant", idempotency_key = key, lease_id = lease_id,
        target = chosen.overlay_owner, envelope = checked, source_approval_id = approval_id,
        source_approval_proposal_digest = proposal_digest, source_approval_owner_incarnation = incarnation,
        granted_by = tostring(approval.decider_id or actor_id), ttl_seconds = payload.ttl_seconds,
        max_applies = payload.max_applies})
end

return M

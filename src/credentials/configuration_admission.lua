local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Base = {path: string, content: string, digest: string}
type Status = {needs_setup: boolean, path: string}
type IO = {measure: () -> (Base?, string?), admitted: (Base) -> (boolean?, string?),
    finish: (Base?, string, Object) -> string?, receipt: (string) -> (Object?, string?), call: (string, Object) -> (unknown, string?), wait: () -> ()}
local function call(io: IO, target: string, request: Object): (Object?, string?)
    local raw, err = io.call(target, request)
    local reply = bounds.object(raw)
    if err or not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, tostring(err or (fault and fault.message) or "Configuration setup could not reach Needs you. Open Agents and choose Setup to try again.")
    end
    return bounds.object(reply.value), nil
end
function M.status(io: IO): (Status?, string?)
    local base, err = io.measure()
    if not base then return nil, err end
    local admitted, admission_error = io.admitted(base)
    if admitted == nil then return nil, admission_error end
    return {needs_setup = not admitted, path = base.path}, nil
end
function M.ensure(io: IO, workspace: string, provider: string, attempt: string?, base_path: string?): (Base?, string?)
    local base, err = io.measure()
    if not base then return nil, err end
    local admitted, admission_error = io.admitted(base)
    if admitted == nil then return nil, admission_error end
    if admitted then return base, nil end
    local proposal: Object = {kind = "operation", ref = "bee.credentials.binding:configuration_setup", revision = "1",
        input_digest = base.digest, payload = {workspace_id = workspace, provider = provider, path = base.path, digest = base.digest, base_path = base_path}}
    local identity = canonical.encode(proposal)
    local key = identity and hash.sha256(identity .. "|" .. (attempt or ""))
    if not key then return nil, "The configuration setup request could not be measured." end
    local requested, request_error = call(io, "bee.approvals.binding:request", {workspace_id = workspace,
        idempotency_key = "configuration:" .. key, request_kind = "permission", policy = "configuration-setup",
        contract_version = 2, presentation = "inbox",
        origin = {attempt_id = attempt}, continuation = {destination = "credentials.configuration", effect_id = "configuration:" .. key, context = {}},
        proposal = proposal, prompt = {text = "Allow Bee to use " .. base.path .. " as the configuration base for " .. provider
            .. "? Bee preserves your provider settings and adds the selected agent's tools and settings to its launch configuration. Approving continues the launch."}})
    if not requested then return nil, request_error end
    local approval_id = bounds.id(requested.approval_id)
    if not approval_id then return nil, "Needs you did not return a configuration setup request." end
    local view = requested
    while view.effect_completed_at == nil do
        io.wait()
        local observed, read_error = call(io, "bee.approvals.binding:read", {approval_id = approval_id})
        if not observed then return nil, read_error end
        if observed.approval_id ~= approval_id then return nil, "Needs you returned a different configuration setup request." end
        view = observed
    end
    local result = bounds.object(view.effect_result)
    if not result or result.ok ~= true then
        return nil, result and bounds.text(result.message, 4096) or "Configuration setup did not complete. Choose Setup in Agents to try again."
    end
    local current, measure_error = io.measure()
    if not current then return nil, measure_error end
    local current_admitted, current_error = io.admitted(current)
    if not current_admitted then return nil, current_error or "The configuration file changed. Choose Setup in Agents to approve the current file." end
    return current, nil
end
local function claim(io: IO, view: Object, approval: string, key: string): (Object?, string?)
    local request: Object = {operation = "claim", approval_id = approval, proposal_digest = view.proposal_digest,
        reviewed_digest = view.reviewed_digest, effect_key = key, owner_incarnation = view.owner_incarnation}
    local raw, err = io.call("bee.approvals.binding:effect", request)
    local reply = bounds.object(raw)
    local fault = reply and bounds.object(reply.error)
    if not err and fault and fault.code == "REVALIDATE" then
        local state = bounds.object(reply.value)
        local current = state and bounds.integer(state.current_incarnation)
        if not current then return nil, "Configuration setup authority identity is unavailable." end
        local validated, validation_error = call(io, "bee.approvals.binding:revalidate", {approval_id = approval,
            proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, owner_incarnation = current})
        if not validated then return nil, validation_error end
        request.owner_incarnation = current
        return call(io, "bee.approvals.binding:effect", request)
    end
    if err or not reply or reply.ok ~= true then return nil, tostring(err or (fault and fault.message) or "Configuration setup effect could not be admitted.") end
    return bounds.object(reply.value), nil
end
function M.consume(io: IO, view: Object): string?
    local approval = bounds.id(view.approval_id)
    local effect = bounds.object(view.effect)
    local key = effect and bounds.id(effect.effect_id)
    if not approval or not key then return "Configuration setup effect identity is missing." end
    local receipt, receipt_error = io.receipt(approval)
    if receipt_error then return receipt_error end
    if not receipt then
        local base: Base? = nil
        local message: string? = nil
        if view.state == "decided" and view.decision == "approved" then
            local proposal = bounds.object(view.proposal)
            local payload = proposal and bounds.object(proposal.payload)
            local measured, measure_error = io.measure()
            if not measured then message = measure_error
            elseif not payload or measured.path ~= payload.path or measured.digest ~= payload.digest then
                message = "The configuration file changed while awaiting approval. Choose Setup in Agents to approve the current file."
            else base = measured end
            local claimed, claim_error = claim(io, view, approval, key)
            if not claimed then return claim_error end
            local admitted_effect = bounds.object(claimed.effect)
            if not admitted_effect then return "Configuration setup admitted no effect." end
            local started, start_error = call(io, "bee.approvals.binding:effect", {operation = "start", approval_id = approval,
                proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, effect_key = key,
                owner_incarnation = admitted_effect.owner_incarnation, expected_revision = admitted_effect.revision})
            if not started then return start_error end
        else
            local proposal = bounds.object(view.proposal)
            local payload = proposal and bounds.object(proposal.payload)
            message = "Configuration setup " .. (view.decision == "denied" and "was denied" or tostring(view.state))
                .. ". Launch ended. Choose Setup in Agents to allow this file: " .. tostring(payload and payload.path) .. "."
        end
        receipt = {ok = base ~= nil, message = message, digest = base and base.digest, proposal_digest = view.proposal_digest}
        local save_error = io.finish(base, approval, receipt)
        if save_error then return save_error end
    elseif view.decision == "approved" then
        local claimed, claim_error = claim(io, view, approval, key)
        if not claimed then return claim_error end
    end
    local completed, complete_error = call(io, "bee.approvals.binding:effect", {operation = "complete", approval_id = approval,
        proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, effect_key = key, result = receipt})
    if not completed then return complete_error end
    return nil
end
return M

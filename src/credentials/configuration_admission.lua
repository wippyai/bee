local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Base = {path: string, content: string, digest: string}
type Status = {needs_setup: boolean, path: string}
type IO = {measure: () -> (Base?, string?), admitted: (Base) -> (boolean?, string?),
    admit: (Base, string) -> string?, call: (string, Object) -> (unknown, string?), wait: () -> ()}
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
function M.ensure(io: IO, workspace: string, provider: string, attempt: string?): (Base?, string?)
    local base, err = io.measure()
    if not base then return nil, err end
    local admitted, admission_error = io.admitted(base)
    if admitted == nil then return nil, admission_error end
    if admitted then return base, nil end
    local proposal: Object = {kind = "operation", ref = "bee.credentials.binding:configuration_setup", revision = "1",
        input_digest = base.digest, payload = {workspace_id = workspace, provider = provider, path = base.path, digest = base.digest}}
    local identity = canonical.encode(proposal)
    local key = identity and hash.sha256(identity .. "|" .. (attempt or ""))
    if not key then return nil, "The configuration setup request could not be measured." end
    local requested, request_error = call(io, "bee.approvals.binding:request", {workspace_id = workspace,
        idempotency_key = "configuration:" .. key, request_kind = "permission", policy = "configuration-setup",
        proposal = proposal, prompt = {text = "Allow Bee to use " .. base.path .. " as the configuration base for " .. provider
            .. "? Bee preserves your provider settings and adds the selected agent's tools and settings to its launch configuration. Approving continues the launch."}})
    if not requested then return nil, request_error end
    local approval_id = bounds.id(requested.approval_id)
    if not approval_id then return nil, "Needs you did not return a configuration setup request." end
    local view = requested
    while view.state == "pending" do
        io.wait()
        local observed, read_error = call(io, "bee.approvals.binding:read", {approval_id = approval_id})
        if not observed then return nil, read_error end
        if observed.approval_id ~= approval_id then return nil, "Needs you returned a different configuration setup request." end
        view = observed
    end
    if view.state ~= "decided" or view.decision ~= "approved" then
        return nil, "Configuration setup " .. (view.decision == "denied" and "was denied" or tostring(view.state))
            .. ". Launch ended. Choose Setup in Agents to allow this file: " .. base.path .. "."
    end
    local current, measure_error = io.measure()
    if not current then return nil, measure_error end
    if current.digest ~= base.digest or current.path ~= base.path then
        return nil, "The configuration file changed while awaiting approval. Open Agents and choose Setup to approve the current file."
    end
    local save_error = io.admit(current, approval_id)
    if save_error then return nil, save_error end
    return current, nil
end
return M

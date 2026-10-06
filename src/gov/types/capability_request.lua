-- MIT. Runtime capability elevation: one agent attempt asks for one host
-- catalog capability with bounded parameters and a TTL. The request is
-- measured against the host catalog, worded for approval in the catalog's
-- own text, and bound to the thread and attempt that asked. Consumption
-- writes one resources grant row for the authenticated thread actor, or,
-- for a capability the catalog exercises through gateway tools, leaves the
-- consumed approval itself as the grant those tools check; a different
-- attempt, including any child attempt, cannot consume or inherit it. Pure:
-- nothing here talks to an approval owner, a thread or a ledger.
local hash = require("hash")
local bounds = require("bounds")
local clock = require("clock")
local canonical = require("canonical")
local capability_model = require("capability_model")
local capability_grants = require("capability_grants")
local M = {}
M.REVISION = "bee.capability-request@1"
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_PARAMETERS_BYTES = 16384
type Object = {[string]: unknown}
type Context = {thread_id: string, attempt_id: string, action_id: string}
type Decoded = {capability: string, parameters: Object, ttl_ms: integer, idempotency_key: string?}
type Request = {capability: string, template_revision: integer, parameters: capability_model.Parameters, parameters_digest: string,
    ttl_ms: integer, idempotency_key: string?, operations: {capability_model.Grant}, wording: string,
    thread_id: string, attempt_id: string, action_id: string, grant_source: string?, grant_access: string?,
    tools: {string}}
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
local identifier = capability_model.identity
-- decode: the wire shape only; the catalog decides whether the capability
-- exists and what its parameters mean.
function M.decode(raw: unknown): (Decoded?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "capability request must be an object" end
    local unknown_field = bounds.fields(object, {"capability", "parameters", "ttl_ms", "idempotency_key"})
    if unknown_field then return nil, "capability request: " .. unknown_field end
    local name = identifier(object.capability)
    if not name then return nil, "capability is not an identifier" end
    local parameters = bounds.object(object.parameters == nil and {} or object.parameters)
    if not parameters then return nil, "capability parameters must be an object" end
    local encoded, encode_error = canonical.encode(parameters)
    if not encoded then return nil, "capability parameters are not encodable: " .. tostring(encode_error) end
    if #encoded > M.MAX_PARAMETERS_BYTES then
        return nil, "capability parameters exceed " .. tostring(M.MAX_PARAMETERS_BYTES) .. " bytes"
    end
    local ttl = M.DEFAULT_TTL_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 or declared > M.MAX_TTL_MS then
            return nil, "ttl_ms must be between 1 and " .. tostring(M.MAX_TTL_MS)
        end
        ttl = declared
    end
    local key: string? = nil
    if object.idempotency_key ~= nil then
        key = bounds.id(object.idempotency_key)
        if not key then return nil, "idempotency_key is not an identifier" end
    end
    return {capability = name, parameters = parameters, ttl_ms = ttl, idempotency_key = key}, nil
end
local function context_of(raw: unknown): (Context?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "capability context must be an object" end
    local thread_id, attempt_id, action_id = bounds.id(object.thread_id), bounds.id(object.attempt_id), bounds.id(object.action_id)
    if not thread_id or not attempt_id or not action_id then return nil, "capability context needs thread_id, attempt_id and action_id" end
    return {thread_id = thread_id, attempt_id = attempt_id, action_id = action_id}, nil
end
-- Runtime elevation writes one resource-owner row. The catalog and install
-- paths share the capability model; fixed host resolvers create package
-- resources and cannot be redirected into a workspace association.
local function grant_mapping(template: capability_model.Template, parameters: capability_model.Parameters): (string?, string?, string?)
    local raw_resources = template.resources
    if type(raw_resources) ~= "table" then return nil, nil, "capability names no workspace resource grant" end
    local resources = raw_resources
    if #resources ~= 1 then return nil, nil, "capability names no workspace resource grant" end
    local resource = bounds.object(resources[1])
    if not resource then return nil, nil, "capability names no workspace resource grant" end
    local name: string? = nil
    if type(resource.source) ~= "string" then return nil, nil, "capability has no runtime resource source" end
    local parameter = (resource.source):match("^%$([a-z_]+)$")
    local value = parameter and parameters[parameter] or nil
    name = type(value) == "string" and bounds.id(value) or nil
    if not name then return nil, nil, "capability resource is fixed by its host resolver and cannot be elevated as a workspace association" end
    local access: string? = nil
    if resource.mode == "readonly" then access = "read"
    elseif resource.mode == "readwrite" or resource.mode == "write" or resource.mode == "dedicated" then access = "write" end
    if not access then return nil, nil, "capability resource mode is not grantable" end
    return name, access, nil
end
-- request: measure the decoded shape against the host catalog entry under
-- the asking thread and attempt. The wording carries the catalog's own
-- text plus the exact scope it would grant.
function M.request(entry_raw: unknown, context_raw: unknown, raw: unknown): (Request?, string?)
    local decoded, decode_error = M.decode(raw)
    if not decoded then return nil, decode_error end
    local context, context_error = context_of(context_raw)
    if not context then return nil, context_error end
    local catalog_value, catalog_error = capability_model.decode(entry_raw)
    if not catalog_value then return nil, catalog_error end
    local template, template_error = capability_model.template(catalog_value, decoded.capability)
    if not template then return nil, template_error end
    local parameters, _ = capability_model.normalize(catalog_value, decoded.capability, decoded.parameters)
    if not parameters then return nil, "unknown capability or malformed parameters" end
    local operations, resolve_error = capability_model.resolve_normalized(catalog_value, decoded.capability, parameters)
    if not operations then return nil, resolve_error end
    local _, realization_error = capability_grants.installable(operations)
    if realization_error then return nil, realization_error end
    local lines, render_error = capability_model.render(catalog_value, operations)
    if not lines then return nil, render_error end
    -- A capability the catalog exercises through gateway tools is held as
    -- its consumed approval; every other one maps to a workspace resource.
    local source: string?, access: string? = nil, nil
    if #template.tools == 0 then
        local mapped_source, mapped_access, mapping_error = grant_mapping(template, parameters)
        if not mapped_source or not mapped_access then
            return nil, mapping_error or "capability cannot be realized as a workspace resource grant"
        end
        source, access = mapped_source, mapped_access
    end
    local parameters_digest, digest_error = digest_of(parameters)
    if not parameters_digest then return nil, "capability parameters are not measurable: " .. tostring(digest_error) end
    local revision = template.revision
    local wording = table.concat(lines, "\n")
        .. "\nFor attempt " .. context.attempt_id .. " in thread " .. context.thread_id
        .. " for " .. tostring(decoded.ttl_ms) .. "ms"
    return {capability = decoded.capability, template_revision = revision, parameters = parameters,
        parameters_digest = parameters_digest, ttl_ms = decoded.ttl_ms, idempotency_key = decoded.idempotency_key,
        operations = operations, wording = wording, thread_id = context.thread_id, attempt_id = context.attempt_id,
        action_id = context.action_id, grant_source = source, grant_access = access, tools = template.tools}, nil
end
function M.wording(request: Request): string
    return request.wording
end
-- proposal: the approval binds the attempt, the thread, the exact template
-- revision, the measured parameters and the TTL. The kind is the approval
-- owner's attempt proposal; the measured parameters travel as its input
-- digest. The epoch is execution fencing, never part of the proposal.
function M.proposal(request: Request): Object
    local payload: Object = {thread_id = request.thread_id, attempt_id = request.attempt_id, action_id = request.action_id,
        capability = request.capability, template_revision = request.template_revision,
        parameters = request.parameters, parameters_digest = request.parameters_digest, ttl_ms = request.ttl_ms,
        wording = request.wording}
    local measured = digest_of(payload) or ""
    payload.proposal_digest = measured
    return {kind = "attempt", ref = request.attempt_id, action_id = request.action_id, revision = M.REVISION,
        input_digest = request.parameters_digest, payload = payload}
end
local function keyed(prefix: string, request: Request): string
    local sum = hash.sha256(prefix .. "\n" .. request.thread_id .. "\n" .. request.attempt_id
        .. "\n" .. request.capability .. "\n" .. request.parameters_digest)
    return prefix .. "-" .. tostring(sum)
end
-- The deterministic identities: the approval idempotency key the gateway
-- checkpoints before asking, and the effect key consumption reserves. Both
-- are qualified by thread and attempt, so a child attempt replays nothing.
function M.request_key(request: Request): string
    return keyed("capability-request", request)
end
function M.effect_key(request: Request): string
    return keyed("capability-effect", request)
end
-- grant_write: the resources ledger write consumption makes for the
-- authenticated thread actor. The audience is the actor itself: the grant
-- is for that attempt's own placement use, matching launch-time self
-- audience. Policy-only capabilities write no row.
function M.grant_write(request: Request, workspace_id_raw: unknown, thread_actor_raw: unknown): (Object?, string?)
    local source, access = request.grant_source, request.grant_access
    if not source or not access then
        return nil, "capability names no workspace resource grant"
    end
    local workspace_id = bounds.id(workspace_id_raw)
    local thread_actor = bounds.id(thread_actor_raw)
    if not workspace_id or not thread_actor then return nil, "grant workspace and thread actor are required" end
    return {workspace_id = workspace_id, name = source, access = access, purpose = "session",
        audience = thread_actor, subject = thread_actor, thread_id = request.thread_id, attempt_id = request.attempt_id,
        ttl_ms = request.ttl_ms, idempotency_key = M.effect_key(request)}, nil
end
-- check_consumption: the approval belongs to this exact thread, attempt and
-- measured capability before any grant row is written.
function M.check_consumption(request: Request, approval_raw: unknown): (boolean?, string?)
    local approval = bounds.object(approval_raw)
    if not approval then return nil, "approval is invalid" end
    if approval.thread_id ~= request.thread_id or approval.attempt_id ~= request.attempt_id then
        return nil, "approval does not belong to this thread and attempt"
    end
    if approval.capability ~= request.capability or approval.template_revision ~= request.template_revision
        or approval.parameters_digest ~= request.parameters_digest then
        return nil, "approval proposal differs from the requested capability"
    end
    local payload = bounds.object(M.proposal(request).payload)
    local expected = payload and payload.proposal_digest or nil
    if approval.proposal_digest ~= expected then
        return nil, "approval proposal differs from the requested capability"
    end
    return true, nil
end
-- The effect key a tool-exercised grant is consumed under, so the consumed
-- approval names the grant it stands for.
function M.held_effect(approval_id: string): string
    return "capability:" .. approval_id
end
-- held: a tool-exercised grant is the approval, decided as approved and
-- consumed by the subject for this grant, until its TTL runs out from the
-- moment of consumption. Returns the expiry in epoch milliseconds.
function M.held(request: Request, view_raw: unknown, subject: string, tool: string, now_ms: integer): (integer?, string?)
    local view = bounds.object(view_raw)
    local approval_id = view and bounds.id(view.approval_id) or nil
    if not view or not approval_id then return nil, "the approval is malformed" end
    if view.state ~= "decided" or view.decision ~= "approved" then return nil, "the capability is not approved" end
    if view.consumed_effect ~= M.held_effect(approval_id) or view.consumer_id ~= subject then
        return nil, "the approval is not consumed for this grant"
    end
    local exercised = false
    for _, name in ipairs(request.tools) do if name == tool then exercised = true end end
    if not exercised then return nil, "the approved capability is not exercised through " .. tool end
    local consumed = clock.parse(view.consumed_at)
    if not consumed then return nil, "the approval is not consumed for this grant" end
    local expires = math.floor(clock.epoch_seconds(consumed) * 1000) + request.ttl_ms
    if now_ms >= expires then return nil, "the approved capability has expired" end
    return expires, nil
end
return M

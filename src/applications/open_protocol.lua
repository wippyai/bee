-- MIT. The bounded bridge between an admitted agent open call and the
-- existing workspace host/broker request path.
local arguments = require("arguments")
local decode = require("decode")
local contract = require("contract")
local bounds = require("bounds")
local M = {}
type OriginView = {view_id: string, instance_id: string}
type Provenance = {thread_id: string, subject: string, initiating_owner: string, binding_id: string,
    access_approval_id: string, access_proposal_digest: string, surface_revision: integer, surface_digest: string}
type GatewayContext = {binding_id: string, thread_id: string, subject: string, action_id: string, attempt_id: string,
    workspace_id: string, origin_view: OriginView?, provenance: Provenance}
type Request = {version: integer, workspace_id: string, request_id: string, definition_id: string, arguments: {string}, caller_token: string, origin_view: OriginView?, provenance: Provenance}
type Reply = {request_id: string, reply: contract.Reply, display_id: string?}

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end

function M.origin(value: unknown): OriginView?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if key ~= "view_id" and key ~= "instance_id" then return nil end end
    local view_id, instance_id = text(value.view_id, 80), text(value.instance_id, 80)
    if not view_id or not instance_id then return nil end
    return {view_id = view_id, instance_id = instance_id}
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #(value :: string) ~= 64 or not (value :: string):match("^[0-9a-f]+$") then return nil end
    return value :: string
end

-- The host receives only this narrow provenance record.  It is produced from
-- a sealed gateway context; callers cannot add an outer binding or a second
-- authority field when forwarding it across the private host message.
function M.provenance(value: unknown): Provenance?
    local runtime = type(value) == "table" and value or nil
    if not runtime then return nil end
    for key in pairs(runtime) do
        if key ~= "thread_id" and key ~= "subject" and key ~= "initiating_owner" and key ~= "binding_id"
            and key ~= "access_approval_id" and key ~= "access_proposal_digest" and key ~= "surface_revision" and key ~= "surface_digest" then return nil end
    end
    local thread_id = bounds.id(runtime.thread_id)
    local subject = bounds.id(runtime.subject)
    local binding_id = bounds.id(runtime.binding_id)
    local approval_id = bounds.id(runtime.access_approval_id)
    local revision = bounds.count(runtime.surface_revision)
    local proposal_digest, surface_digest = digest(runtime.access_proposal_digest), digest(runtime.surface_digest)
    if not thread_id or not subject or runtime.initiating_owner ~= subject or not binding_id or not approval_id
        or not revision or revision < 1 or not proposal_digest or not surface_digest then return nil end
    return {thread_id = thread_id, subject = subject, initiating_owner = subject, binding_id = binding_id,
        access_approval_id = approval_id, access_proposal_digest = proposal_digest,
        surface_revision = revision, surface_digest = surface_digest}
end

-- Gateway attribution is private call context, created after MCP bearer
-- authentication.  This decoder is still deliberately exact: a direct call
-- to the facade cannot turn a partial or caller-selected record into host
-- provenance.
function M.gateway_context(value: unknown): GatewayContext?
    local context = type(value) == "table" and value or nil
    if not context then return nil end
    for key in pairs(context) do
        if key ~= "binding_id" and key ~= "thread_id" and key ~= "subject" and key ~= "action_id" and key ~= "attempt_id"
            and key ~= "policy_ref" and key ~= "workspace_id" and key ~= "origin_view" and key ~= "application_runtime" then return nil end
    end
    local binding_id = bounds.id(context.binding_id)
    local thread_id = bounds.id(context.thread_id)
    local subject = bounds.id(context.subject)
    local action_id = bounds.id(context.action_id)
    local attempt_id = bounds.id(context.attempt_id)
    local workspace_id = bounds.id(context.workspace_id)
    if not binding_id or not thread_id or not subject or not action_id or not attempt_id or not workspace_id then return nil end
    if context.policy_ref ~= nil and not bounds.id(context.policy_ref) then return nil end
    local origin = M.origin(context.origin_view)
    if context.origin_view ~= nil and not origin then return nil end
    local provenance = M.provenance(context.application_runtime)
    if not provenance or provenance.thread_id ~= thread_id or provenance.subject ~= subject or provenance.binding_id ~= binding_id then return nil end
    return {binding_id = binding_id, thread_id = thread_id, subject = subject, action_id = action_id, attempt_id = attempt_id,
        workspace_id = workspace_id, origin_view = origin, provenance = provenance}
end

function M.request(value: unknown, workspace_id: string): Request?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "request_id"
            and key ~= "definition_id" and key ~= "arguments" and key ~= "caller_token" and key ~= "origin_view" and key ~= "provenance" then return nil end
    end
    local request_id = text(value.request_id, 80)
    local definition_id = text(value.definition_id, 160)
    local caller_token = text(value.caller_token, 160)
    local args = arguments.decode(value.arguments)
    if not request_id or not definition_id or not caller_token or not args then return nil end
    if not caller_token:match("^bee%.application%.open/[0-9a-f-]+$") then return nil end
    local origin = M.origin(value.origin_view)
    if value.origin_view ~= nil and not origin then return nil end
    local provenance = M.provenance(value.provenance)
    if not provenance then return nil end
    return {version = 1, workspace_id = workspace_id, request_id = request_id,
        definition_id = definition_id, arguments = args, caller_token = caller_token, origin_view = origin, provenance = provenance}
end

-- The host forwards the broker's typed application reply and adds only the
-- workspace/request identity needed to route it back to the exact caller.
function M.reply(value: unknown, workspace_id: string): Reply?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "request_id" and key ~= "reply" and key ~= "display_id" then return nil end
    end
    local request_id = text(value.request_id, 80)
    local reply = type(value.reply) == "table" and decode.reply(value.reply) or nil
    if not request_id or not reply or reply.request_id ~= request_id or reply.workspace_id ~= workspace_id then return nil end
    local display_id = text(value.display_id, 160)
    if value.display_id ~= nil and not display_id then return nil end
    return {request_id = request_id, reply = reply, display_id = display_id}
end

return M

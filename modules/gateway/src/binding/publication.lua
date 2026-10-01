-- MIT. The Hub publication tool surface: one binding per tool, like every
-- other tool. Filing and polling share the thread-bound approval the person
-- decides on; the owner worker performs the approved upload after the
-- approval wakes it, never the polling agent. This surface lives apart from
-- the gateway authority module, which is at the checker's inference budget;
-- it resolves its caller through that module's shared bound-subject door.
local bounds = require("bounds")
local gateway = require("gateway")
local hubpublish = require("hubpublish")
local M = {}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Object = {[string]: unknown}
type OriginView = {view_id: string, instance_id: string}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, owner_incarnation: integer, carrier_epoch: integer,
    tools: {string}, hooks: {string}, epoch: integer, credential_generation: integer, expires_at: string, revoked: boolean, sealed: boolean, policy_ref: string?, workspace_id: string?, workspace_name: string, origin_view: OriginView?}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}}
end
local function publication_call(value: unknown, fields: {string}): (Binding?, string?, unknown?, Reply?)
    local binding, refusal = gateway.own_binding(value)
    if not binding then return nil, nil, nil, refusal end
    local policy_name, policy_refusal = hubpublish.approval_policy()
    if not policy_name then return nil, nil, nil, policy_refusal end
    local object = bounds.object(value) or {}
    local request: {[string]: unknown} = {}
    for _, name in ipairs(fields) do request[name] = object[name] end
    return binding, policy_name, request, nil
end
function M.publish_request(value: unknown): Reply
    local binding, policy_name, request, refusal = publication_call(value, {"component", "version", "visibility", "source"})
    if not binding or not policy_name then return assert(refusal) end
    return hubpublish.request(hubpublish.port(binding), binding, policy_name, request)
end
function M.publish_status(value: unknown): Reply
    local binding, policy_name, request, refusal = publication_call(value, {"request_id"})
    if not binding or not policy_name then return assert(refusal) end
    return hubpublish.status(hubpublish.port(binding), binding, policy_name, request)
end
return M

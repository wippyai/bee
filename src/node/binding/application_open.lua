-- MIT. An agent opens an application on the person's desktop: the node owner
-- presents it on the desktops a display shows for the agent's workspace, the
-- same way it presents Needs you. The workspace is the authenticated caller's
-- and the gateway binding that asked carries the approved application runtime
-- grant; the owner starts only applications admitted in that workspace.
local security = require("security")
local system = require("system")
local ctx = require("ctx")
local bounds = require("bounds")
local arguments = require("arguments")
local client = require("client")

type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local GATEWAY_BINDING = "bee.gateway.binding"

local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

-- request is the owner's name for this agent's open: one per binding and
-- idempotency key, so a retry finds what the first attempt opened.
local function request(key: string): (string?, string?)
    local attribution = bounds.object(ctx.get(GATEWAY_BINDING))
    local binding = attribution and bounds.id(attribution.binding_id) or nil
    local runtime = attribution and bounds.object(attribution.application_runtime) or nil
    if not binding or not runtime or runtime.binding_id ~= binding or not bounds.id(runtime.access_approval_id) then
        return nil, "the call is not bound to an approved application runtime"
    end
    return binding .. "/" .. key, nil
end

local function handle(raw: unknown): Reply
    local object = bounds.object(raw)
    if not object or bounds.fields(object, {"definition_id", "arguments", "idempotency_key"}) then
        return fail("INVALID", "open takes definition_id, arguments and idempotency_key")
    end
    local definition_id = bounds.id(object.definition_id)
    local key = bounds.id(object.idempotency_key)
    local literal = arguments.decode(object.arguments)
    if not definition_id then return fail("INVALID", "definition_id must be an identifier") end
    if not key or #key > 64 then return fail("INVALID", "idempotency_key must be a bounded identifier") end
    if not literal then return fail("INVALID", "arguments must be bounded literal strings") end
    local actor = security.actor()
    local metadata = actor and bounds.object(actor:meta()) or nil
    local workspace = metadata and bounds.id(metadata.workspace_id) or nil
    if not workspace then return fail("DENIED", "opening an application needs an authenticated workspace caller") end
    local named, binding_error = request(key)
    if not named then return fail("DENIED", binding_error or "application runtime is not approved") end
    local value, open_error = client.call(assert(system.node.id()), "present",
        {workspace = workspace, app = definition_id, arguments = literal, request = named})
    if not value then return fail("FAILED", tostring(open_error)) end
    local opened = bounds.array(value.opened, 16)
    local first = opened and bounds.object(opened[1]) or nil
    if not first then return fail("FAILED", "the node opened no window") end
    return {ok = true, value = {workspace_id = workspace, definition_id = definition_id, instance_id = first.id,
        view_id = first.id, title = first.title, desktop = first.desktop, reused = first.existing == true}, error = nil}
end

return {handle = handle}

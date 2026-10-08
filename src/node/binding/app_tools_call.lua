-- MIT. The application tools of the caller's workspace: list names the
-- tools its applications offer agents, call runs one of them. The workspace
-- is the authenticated caller's; a call re-reads discovery and the live
-- grant, then runs the tool function as the application, with the actor and
-- exact scope the node gives the application's own instances. The gateway
-- binding that asked travels in the call context and names the instance.
local funcs = require("funcs")
local security = require("security")
local ctx = require("ctx")
local bounds = require("bounds")
local application = require("application")
local app_tools = require("app_tools")
local requests = require("requests")
local peers = require("peers")

type Object = {[string]: unknown}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local GATEWAY_BINDING = "bee.gateway.binding"

local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end

local function caller_workspace(): string?
    local actor = security.actor()
    local metadata = actor and bounds.object(actor:meta()) or nil
    return metadata and bounds.id(metadata.workspace_id) or nil
end

local call: (unknown) -> Reply

local function list(raw: unknown): Reply
    local request, invalid = requests.decode(raw)
    if not request then return fail("INVALID", invalid or "invalid app_tools request") end
    local workspace = caller_workspace()
    if not workspace then return fail("DENIED", "application tools need an authenticated workspace caller") end
    if request.node ~= nil then return peers.tools(request) end
    if request.operation == "call" then return call({tool = request.tool, arguments = request.arguments}) end
    local found, discovery_error = app_tools.discover(workspace)
    if not found then return fail("UNAVAILABLE", tostring(discovery_error)) end
    return {ok = true, value = found, error = nil}
end

-- The instance an agent's call runs as: one per gateway binding, so the
-- application can tell the agent sessions apart.
local function instance_id(): string
    local attribution = bounds.object(ctx.get(GATEWAY_BINDING))
    local binding = attribution and bounds.id(attribution.binding_id) or nil
    if binding and not binding:find(":", 1, true) and #binding <= 70 then return "agent-" .. binding end
    return "agent"
end

-- call: {tool, arguments}. The tool's reply is the application's
-- {ok, value, error} envelope, returned as it is.
call = function(raw: unknown): Reply
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"tool", "arguments"}) then
        return fail("INVALID", "call takes tool and arguments")
    end
    local alias = bounds.line(request.tool, 64)
    local arguments = bounds.object(request.arguments == nil and {} or request.arguments)
    if not alias or not arguments then return fail("INVALID", "call takes a tool name and an arguments object") end
    local workspace = caller_workspace()
    if not workspace then return fail("DENIED", "application tools need an authenticated workspace caller") end
    local tool, find_error = app_tools.find(workspace, alias)
    if find_error then return fail("UNAVAILABLE", find_error) end
    if not tool then return fail("NOT_FOUND", "no application in this workspace offers tool " .. alias) end
    local definition, definition_error = application.definition(tool.definition_id)
    if not definition then return fail("UNAVAILABLE", tostring(definition_error)) end
    local actor, actor_error = application.actor(workspace, instance_id(), definition, 1)
    if not actor then return fail("UNAVAILABLE", tostring(actor_error)) end
    local scope, scope_error = application.scope(definition, workspace)
    if not scope then return fail("UNAVAILABLE", tostring(scope_error)) end
    local acted = funcs.new():with_actor(actor)
    local scoped = acted and acted:with_scope(scope)
    if not scoped then return fail("UNAVAILABLE", "application authority is unavailable") end
    local result, call_error = scoped:call(tool.ref, arguments)
    if call_error then return fail("FAILED", tostring(call_error)) end
    local reply = bounds.object(result)
    if not reply or type(reply.ok) ~= "boolean" or bounds.fields(reply, {"ok", "value", "error"}) then
        return fail("FAILED", "tool " .. alias .. " returned no {ok, value, error} reply")
    end
    if reply.ok then return {ok = true, value = reply.value, error = nil} end
    local fault = bounds.object(reply.error)
    local code = fault and bounds.id(fault.code) or nil
    local message = fault and bounds.text(fault.message, 4096) or nil
    if not code or not message then return fail("FAILED", "tool " .. alias .. " failed without an error code and message") end
    return {ok = false, value = reply.value, error = {code = code, message = message}}
end

return {list = list, call = call}

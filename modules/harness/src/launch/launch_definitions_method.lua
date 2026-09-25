-- MIT. The public launch-discovery facade the gateway tool maps to. It carries
-- only the caller's binding workspace into the host-named launch scope; the
-- backend reads the caller's own launch policy allow-list there. A caller
-- asking about a workspace other than its binding's must hold the launch
-- action on that workspace in its own scope.
local ctx = require("ctx")
local bounds = require("bounds")
local caller_launch = require("caller_launch")
local BACKEND = "bee.harness.launch:launch_definitions_backend"
local BINDING_KEY = "bee.gateway.binding"
local function handle(raw: unknown): {[string]: unknown}
    local value = bounds.object(raw or {})
    if not value then return {ok = false, error = {code = "INVALID", message = "launch discovery takes no arguments"}} end
    local unknown_field = bounds.fields(value, {"workspace_id"})
    if unknown_field then return {ok = false, error = {code = "INVALID", message = unknown_field}} end
    local requested: string? = nil
    if value.workspace_id ~= nil then
        requested = bounds.id(value.workspace_id)
        if not requested then return {ok = false, error = {code = "INVALID", message = "workspace_id is not an identifier"}} end
    end
    local attribution = bounds.object((ctx.get(BINDING_KEY)))
    local bound = attribution and bounds.id(attribution.workspace_id)
    local scoped, refused = caller_launch.executor(requested, bound)
    if not scoped then return {ok = false, error = refused} end
    local request: {[string]: unknown} = {}
    if requested ~= nil then request.workspace_id = requested end
    local result, call_error = scoped:call(BACKEND, request)
    if call_error then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(call_error)}} end
    local reply = bounds.object(result)
    if not reply then return {ok = false, error = {code = "INTERNAL", message = "the launch discovery backend returned a malformed reply"}} end
    return reply
end
return {handle = handle}

-- MIT. The public agent-launch facade the gateway tool maps to. It validates
-- the bounded request as the caller's bound subject, then enters the
-- host-named launch scope; the backend resolves the caller's own launch
-- policy and starts the child. A caller launching into a workspace other than
-- its binding's must hold the launch action on that workspace in its own
-- scope; the launch then runs as the same actor bound to that workspace.
local ctx = require("ctx")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local caller_launch = require("caller_launch")
local BACKEND = "bee.harness.launch:agent_launch_backend"
local BINDING_KEY = "bee.gateway.binding"
local function handle(raw: unknown): {[string]: unknown}
    local request, invalid = agent_launch.decode_request(raw)
    if not request then return {ok = false, error = {code = "INVALID", message = invalid or "invalid launch request"}} end
    local attribution = bounds.object((ctx.get(BINDING_KEY)))
    local bound = attribution and bounds.id(attribution.workspace_id)
    local scoped, refused = caller_launch.executor(request.workspace_id, bound)
    if not scoped then return {ok = false, error = refused} end
    local result, call_error = scoped:call(BACKEND, request)
    if call_error then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(call_error)}} end
    local reply = bounds.object(result)
    if not reply then return {ok = false, error = {code = "INTERNAL", message = "the launch backend returned a malformed reply"}} end
    return reply
end
return {handle = handle}

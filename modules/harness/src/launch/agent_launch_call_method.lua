-- MIT. The public agent-launch facade the gateway tool maps to. It validates
-- the bounded request as the caller's bound subject, then enters the
-- host-named launch scope; the backend resolves the caller's own launch
-- policy and starts the child. Actor context is inherited throughout.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local BACKEND = "bee.harness.launch:agent_launch_backend"
local EXECUTION_SCOPE = "bee.harness.launch:agent_launch_execution_scope"
local function handle(raw: unknown): {[string]: unknown}
    local request, invalid = agent_launch.decode_request(raw)
    if not request then return {ok = false, error = {code = "INVALID", message = invalid or "invalid launch request"}} end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(scope_error or "the agent launch scope is unavailable")}} end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return {ok = false, error = {code = "DENIED", message = tostring(executor_error or "the agent launch scope is denied")}} end
    local result, call_error = executor:call(BACKEND, request)
    if call_error then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(call_error)}} end
    local reply = bounds.object(result)
    if not reply then return {ok = false, error = {code = "INTERNAL", message = "the launch backend returned a malformed reply"}} end
    return reply
end
return {handle = handle}

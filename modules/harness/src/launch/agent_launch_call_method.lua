-- MIT. The public agent-launch facade the gateway tool maps to. It validates
-- the bounded request as the caller's bound subject, then enters the
-- host-named launch scope; the backend resolves the caller's own launch
-- policy and starts the child. A caller launching into a workspace other than
-- its binding's must hold the launch action on that workspace in its own
-- scope; the launch then runs as the same actor bound to that workspace.
local ctx = require("ctx")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local BACKEND = "bee.harness.launch:agent_launch_backend"
local BINDING_KEY = "bee.gateway.binding"
local EXECUTION_SCOPE = "bee.harness.launch:agent_launch_execution_scope"
local function handle(raw: unknown): {[string]: unknown}
    local request, invalid = agent_launch.decode_request(raw)
    if not request then return {ok = false, error = {code = "INVALID", message = invalid or "invalid launch request"}} end
    local executor = funcs.new()
    local requested = request.workspace_id
    if requested then
        local attribution = bounds.object((ctx.get(BINDING_KEY)))
        local bound = attribution and bounds.id(attribution.workspace_id)
        if requested ~= bound then
            if not security.can(agent_launch.LAUNCH_ACTION, requested) then
                return {ok = false, error = {code = "DENIED", message = "this agent may not launch into workspace " .. requested}}
            end
            local current = security.actor()
            local id = current and bounds.id(current:id())
            if not id then return {ok = false, error = {code = "UNAUTHENTICATED", message = "the call has no actor"}} end
            local actor, actor_error = security.new_actor(id, {workspace_id = requested})
            if not actor then return {ok = false, error = {code = "DENIED", message = tostring(actor_error)}} end
            local acted, acted_error = executor:with_actor(actor)
            if not acted then return {ok = false, error = {code = "DENIED", message = tostring(acted_error)}} end
            executor = acted
        end
    end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(scope_error or "the agent launch scope is unavailable")}} end
    local scoped, executor_error = executor:with_scope(scope)
    if not scoped then return {ok = false, error = {code = "DENIED", message = tostring(executor_error or "the agent launch scope is denied")}} end
    local result, call_error = scoped:call(BACKEND, request)
    if call_error then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(call_error)}} end
    local reply = bounds.object(result)
    if not reply then return {ok = false, error = {code = "INTERNAL", message = "the launch backend returned a malformed reply"}} end
    return reply
end
return {handle = handle}

-- MIT. The application facade for managed agents: launch one, read its
-- status, wait for it through its thread and cancel it. It runs as the
-- calling application's own actor. A launch needs the host to grant the
-- application bee.harness.launch on that definition and, for another
-- workspace, bee.workspaces.launch on it; status, wait and cancel need the
-- application to belong to the child's thread, and cancel to own its
-- attempt. The backend runs in the host-named launch scope and mints no
-- grant, credential, trait or overlay authority of its own.
local security = require("security")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local caller_launch = require("caller_launch")
local BACKEND = "bee.harness.launch:agent_call_backend"
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function handle(raw: unknown): Reply
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "request must be an object") end
    local current = security.actor()
    local bound = current and bounds.id(current:meta().workspace_id)
    if not bound then return fail("UNAUTHENTICATED", "the call is not bound to a workspace") end
    local requested: string? = nil
    if object.operation == "launch" then
        local body: {[string]: unknown} = {}
        for key, value in pairs(object) do
            if key ~= "operation" then body[key] = value end
        end
        local request, invalid = agent_launch.decode_request(body)
        if not request then return fail("INVALID", invalid or "invalid launch request") end
        if not security.can(agent_launch.APPLICATION_ACTION, request.definition_ref) then
            return fail("LAUNCH_NOT_PERMITTED", "this application may not launch " .. request.definition_ref)
        end
        requested = request.workspace_id
    end
    local scoped, refused = caller_launch.executor(requested, bound)
    if not scoped then return fail(refused.code, refused.message) end
    local result, call_error = scoped:call(BACKEND, object)
    if call_error then return fail("UNAVAILABLE", tostring(call_error)) end
    local reply = bounds.object(result)
    if not reply then return fail("INTERNAL", "the agent backend returned a malformed reply") end
    return reply :: unknown as Reply
end
return {handle = handle}

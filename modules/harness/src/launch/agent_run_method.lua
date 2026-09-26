-- MIT. The public managed-run facade the gateway's run_status, run_wait and
-- run_cancel tools map to. It decodes only the read/wait/cancel operations and
-- runs them as the caller's bound subject in the host-named launch scope. It
-- cannot launch: agent_launch_call is the only way to start work. The backend
-- checks the caller launched the run before it answers, so a caller reads,
-- waits on and cancels exactly the runs it started and no other.
local bounds = require("bounds")
local security = require("security")
local caller_launch = require("caller_launch")
local BACKEND = "bee.harness.launch:agent_call_backend"
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function handle(raw: unknown): {[string]: unknown}
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "request must be an object") end
    local operation = bounds.member(object.operation, {"status", "wait", "cancel"})
    if not operation then return fail("INVALID", "operation must be status, wait or cancel") end
    local current = security.actor()
    local bound = current and bounds.id(current:meta().workspace_id)
    if not bound then return fail("UNAUTHENTICATED", "the call is not bound to a workspace") end
    local scoped, refused = caller_launch.executor(nil, bound)
    if not scoped then return fail(refused.code, refused.message) end
    local result, call_error = scoped:call(BACKEND, object)
    if call_error then return fail("UNAVAILABLE", tostring(call_error)) end
    local reply = bounds.object(result)
    if not reply then return fail("INTERNAL", "the run backend returned a malformed reply") end
    return reply
end
return {handle = handle}

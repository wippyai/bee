-- MIT. Test-only reader of a managed run's reconciled status and wait.
local managed_run = require("managed_run")
local bounds = require("bounds")

local function handle(request: unknown)
    local object = bounds.object(request)
    if not object then return {ok = false, error = {code = "INVALID", message = "request must be an object"}} end
    local thread_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.attempt_id)
    if not thread_id or not attempt_id then return {ok = false, error = {code = "INVALID", message = "run identity is invalid"}} end
    local run = {thread_id = thread_id, attempt_id = attempt_id}
    if object.operation == "wait" then
        return managed_run.wait(run, 0, {reconcile_prestart = true})
    end
    local current, refused = managed_run.status(run, {reconcile_prestart = true})
    if not current then return refused or {ok = false, error = {code = "UNAVAILABLE", message = "the attempt did not answer"}} end
    return {ok = true, error = nil, value = current}
end

return {handle = handle}

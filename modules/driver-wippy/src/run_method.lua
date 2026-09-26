-- MIT. Entry point for the in-process driver adapter and shared run lifecycle.
local bounds = require("bounds")
local runner = require("runner")
local managed_run = require("managed_run")
local types = require("types")

local MAX_WAIT_MS = 30000
local DRIVER_STATUS = {carrier_epoch_starts = true, cancel_status_first = true,
    cancel_status_pending = true, tolerate_checkpoint_failure = true}

local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function scoped_status(value: {[string]: unknown}): {[string]: unknown}
    return {thread_id = value.thread_id, attempt_id = value.attempt_id, scope = "attempt",
        state = value.state, outcome = value.outcome, answer = value.answer}
end

local function handle(raw: unknown): {[string]: unknown}
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "request must be an object") end

    local operation = object.operation
    if operation == nil or operation == "run" then
        local thread_id = bounds.id(object.thread_id)
        local action_id = bounds.id(object.action_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not action_id or not attempt_id then
            return fail("INVALID", "run requires thread_id, action_id and attempt_id")
        end
        local run_req: types.RunRequest = {
            thread_id = thread_id :: string,
            action_id = action_id :: string,
            attempt_id = attempt_id :: string,
            agent_ref = bounds.id(object.agent_ref),
            brief = bounds.text(object.brief, 16384),
            workspace_id = bounds.id(object.workspace_id),
            host_config = bounds.object(object.host_config) :: types.HostConfig?,
            idempotency_key = bounds.id(object.idempotency_key) or bounds.text(object.idempotency_key, 128),
            carrier_epoch = bounds.integer(object.carrier_epoch),
        }
        local function execute_in_process(context: types.ExecutionContext, _request: {[string]: unknown}): types.ExecutionResult
            return runner.execute(context, run_req)
        end
        local raw_result = managed_run.execute(run_req, execute_in_process)
        local result = raw_result :: types.RunResult
        return {
            ok = result.ok,
            error = result.error and {code = "FAILED", message = result.error} or nil,
            value = {
                thread_id = result.thread_id,
                action_id = result.action_id,
                attempt_id = result.attempt_id,
                outcome = result.outcome,
                answer = result.answer,
                state = result.state,
                receipt = result.receipt,
            },
        }
    elseif operation == "status" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "status requires thread_id and attempt_id") end
        local current = managed_run.status({thread_id = thread_id :: string, attempt_id = attempt_id :: string}, DRIVER_STATUS)
        if not current then return fail("FAILED", "the attempt did not answer") end
        return {ok = true, value = scoped_status(current)}
    elseif operation == "wait" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "wait requires thread_id and attempt_id") end
        local wait_ms = bounds.integer(object.wait_ms) or 1000
        if wait_ms < 0 then return fail("INVALID", "wait_ms must be a nonnegative integer") end
        if wait_ms > MAX_WAIT_MS then wait_ms = MAX_WAIT_MS end
        local reply = managed_run.wait({thread_id = thread_id :: string, attempt_id = attempt_id :: string}, wait_ms, DRIVER_STATUS)
        local value = bounds.object(reply.value)
        if reply.ok ~= true or not value then return reply end
        return {ok = true, value = scoped_status(value)}
    elseif operation == "cancel" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "cancel requires thread_id and attempt_id") end
        local idempotency_key = bounds.id(object.idempotency_key)
            or ((attempt_id :: string) .. "-cancel")
        local reply = managed_run.cancel({thread_id = thread_id :: string, attempt_id = attempt_id :: string},
            0, idempotency_key, {prestart = "signal"})
        local value = bounds.object(reply.value)
        if reply.ok ~= true or not value then return reply end
        local scoped = scoped_status(value)
        scoped.idempotency_key = value.idempotency_key or idempotency_key
        return {ok = true, value = scoped}
    else
        return fail("INVALID", "unsupported operation: " .. tostring(operation))
    end
end

return {handle = handle}

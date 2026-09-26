-- MIT. Run method for native Wippy driver: honors run/status/wait/cancel lifecycle.
local bounds = require("bounds")
local funcs = require("funcs")
local runner = require("runner")
local types = require("types")

local CARRIER_OPS = "bee.threads.carrier"
local DELIVERY = "bee.threads.delivery"
local THREADS = "bee.threads.service"

local MAX_WAIT_MS = 30000

local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function carrier_value(reply: unknown): {[string]: unknown}?
    if type(reply) ~= "table" then return nil end
    local object = reply :: {[string]: unknown}
    if object.ok ~= true or type(object.value) ~= "table" then return nil end
    return object.value :: {[string]: unknown}
end

local function status_of(thread_id: string, attempt_id: string): {[string]: unknown}
    local cancel_res, _ = funcs.call(CARRIER_OPS .. ":cancel_status", {thread_id = thread_id, attempt_id = attempt_id})
    local cancel_val = carrier_value(cancel_res)
    if cancel_val and (cancel_val.state == "cancelling" or cancel_val.state == "ended") then
        return {
            thread_id = thread_id,
            attempt_id = attempt_id,
            scope = "attempt",
            state = cancel_val.state,
            outcome = "cancelled",
        }
    end

    local res, err = funcs.call(CARRIER_OPS .. ":checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
    local val = carrier_value(res)
    if err or not val then
        return {thread_id = thread_id, attempt_id = attempt_id, scope = "attempt", state = "starting"}
    end

    local state = "starting"
    if val.attempt_state == "ended" then
        state = "ended"
    elseif val.attempt_state == "running" or val.carrier_epoch ~= nil then
        state = "running"
    end

    local answer: string? = nil
    local outcome: string? = nil
    if state == "ended" then
        if type(val.attempt_outcome) == "string" then
            outcome = val.attempt_outcome :: string
        end
        if type(val.checkpoint) == "table" then
            local cp = val.checkpoint :: {[string]: unknown}
            if type(cp.terminal) == "table" then
                local term = cp.terminal :: {[string]: unknown}
                if type(term.answer) == "string" then answer = term.answer :: string end
                if outcome == nil and type(term.outcome) == "string" then outcome = term.outcome :: string end
            end
        end
    end

    return {
        thread_id = thread_id,
        attempt_id = attempt_id,
        scope = "attempt",
        state = state,
        outcome = outcome,
        answer = answer,
    }
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

        local tid: string = thread_id :: string
        local aid: string = action_id :: string
        local attid: string = attempt_id :: string

        local agent_ref = bounds.id(object.agent_ref)
        local brief = bounds.text(object.brief, 16384)
        local workspace_id = bounds.id(object.workspace_id)
        local idk = bounds.id(object.idempotency_key) or bounds.text(object.idempotency_key, 128)
        local carrier_epoch = bounds.integer(object.carrier_epoch)

        local run_req: types.RunRequest = {
            thread_id = tid,
            action_id = aid,
            attempt_id = attid,
            agent_ref = agent_ref and (agent_ref :: string) or nil,
            brief = brief and (brief :: string) or nil,
            workspace_id = workspace_id and (workspace_id :: string) or nil,
            host_config = bounds.object(object.host_config) :: types.HostConfig?,
            idempotency_key = idk and (idk :: string) or nil,
            carrier_epoch = carrier_epoch,
        }

        local result = runner.run(run_req)
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
        return {ok = true, value = status_of(thread_id :: string, attempt_id :: string)}
    elseif operation == "wait" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "wait requires thread_id and attempt_id") end
        local wait_ms = bounds.integer(object.wait_ms) or 1000
        if wait_ms < 0 then return fail("INVALID", "wait_ms must be a nonnegative integer") end
        if wait_ms > MAX_WAIT_MS then wait_ms = MAX_WAIT_MS end

        local cur = status_of(thread_id :: string, attempt_id :: string)
        if cur.state == "ended" or wait_ms <= 0 then
            return {ok = true, value = cur}
        end

        funcs.call(DELIVERY .. ":watch", {thread_id = thread_id, after_sequence = 0, wait_ms = wait_ms})
        return {ok = true, value = status_of(thread_id :: string, attempt_id :: string)}
    elseif operation == "cancel" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "cancel requires thread_id and attempt_id") end
        local idempotency_key = bounds.id(object.idempotency_key) or ((attempt_id :: string) .. "-cancel")

        local cancel_res, cancel_err = funcs.call(CARRIER_OPS .. ":cancel_intent", {
            thread_id = thread_id :: string,
            attempt_id = attempt_id :: string,
            state = "cancelling",
            idempotency_key = idempotency_key,
        })
        local recorded = carrier_value(cancel_res)
        if cancel_err or not recorded then
            local detail: string = cancel_err and tostring(cancel_err) or "cancel intent refused"
            if type(cancel_res) == "table" then
                local fault = (cancel_res :: {[string]: unknown}).error
                if type(fault) == "table" and type((fault :: {[string]: unknown}).message) == "string" then
                    detail = (fault :: {[string]: unknown}).message :: string
                end
            end
            return fail("FAILED", "cancel intent: " .. detail)
        end
        return {
            ok = true,
            value = {
                thread_id = thread_id :: string,
                attempt_id = attempt_id :: string,
                scope = "attempt",
                state = "cancelling",
                idempotency_key = recorded.idempotency_key or idempotency_key,
            }
        }
    else
        return fail("INVALID", "unsupported operation: " .. tostring(operation))
    end
end

return {handle = handle}

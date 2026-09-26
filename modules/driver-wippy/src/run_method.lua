-- MIT. Run method for native Wippy driver: honors run/status/wait/cancel lifecycle.
local bounds = require("bounds")
local funcs = require("funcs")
local runner = require("runner")
local types = require("types")

local CARRIER_OPS = "bee.threads.carrier"
local DELIVERY = "bee.threads.delivery"
local THREADS = "bee.threads.service"

local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function status_of(thread_id: string, attempt_id: string): {[string]: unknown}
    local res, err = funcs.call(CARRIER_OPS .. ":checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
    if err or not res or type(res) ~= "table" or (res :: {[string]: unknown}).ok ~= true then
        -- Check cancel status
        local cancel_res, _ = funcs.call(CARRIER_OPS .. ":cancel_status", {thread_id = thread_id, attempt_id = attempt_id})
        if cancel_res and type(cancel_res) == "table" and (cancel_res :: {[string]: unknown}).ok == true then
            local cval = (cancel_res :: {[string]: unknown}).value :: {[string]: unknown}?
            if cval and cval.state == "ended" then
                return {thread_id = thread_id, attempt_id = attempt_id, state = "ended", outcome = "cancelled"}
            end
        end
        return {thread_id = thread_id, attempt_id = attempt_id, state = "starting"}
    end

    local val = (res :: {[string]: unknown}).value :: {[string]: unknown}
    local ended = val.attempt_state == "ended"
    local state = "starting"
    if ended then
        state = "ended"
    elseif val.attempt_state == "running" or val.carrier_epoch ~= nil then
        state = "running"
    end

    local answer: string? = nil
    local cp = val.checkpoint :: {[string]: unknown}?
    if cp and type(cp.terminal) == "table" then
        local term = cp.terminal :: {[string]: unknown}
        if type(term.answer) == "string" then answer = term.answer :: string end
    end

    return {
        thread_id = thread_id,
        attempt_id = attempt_id,
        state = state,
        outcome = ended and (val.attempt_outcome or (cp and cp.terminal and (cp.terminal :: {[string]: unknown}).outcome)) or nil,
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
        local session_ref = bounds.id(object.session_ref)

        local run_req: types.RunRequest = {
            thread_id = tid,
            action_id = aid,
            attempt_id = attid,
            agent_ref = agent_ref and (agent_ref :: string) or nil,
            brief = brief and (brief :: string) or nil,
            workspace_id = workspace_id and (workspace_id :: string) or nil,
            host_config = bounds.object(object.host_config) :: types.HostConfig?,
            idempotency_key = idk and (idk :: string) or nil,
            carrier_epoch = carrier_epoch and (carrier_epoch :: integer) or nil,
            resume = object.resume == true,
            session_ref = session_ref and (session_ref :: string) or nil,
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

        local cur = status_of(thread_id :: string, attempt_id :: string)
        if cur.state == "ended" or wait_ms <= 0 then
            return {ok = true, value = cur}
        end

        funcs.call(DELIVERY .. ":watch", {thread_id = thread_id, wait_ms = wait_ms})
        return {ok = true, value = status_of(thread_id :: string, attempt_id :: string)}
    elseif operation == "cancel" then
        local thread_id = bounds.id(object.thread_id)
        local attempt_id = bounds.id(object.attempt_id)
        if not thread_id or not attempt_id then return fail("INVALID", "cancel requires thread_id and attempt_id") end
        local idempotency_key = bounds.id(object.idempotency_key) or ((attempt_id :: string) .. "-cancel")

        funcs.call(CARRIER_OPS .. ":cancel_intent", {
            thread_id = thread_id :: string,
            attempt_id = attempt_id,
            state = "cancelling",
            idempotency_key = idempotency_key,
        })
        return {ok = true, value = status_of(thread_id, attempt_id)}
    else
        return fail("INVALID", "unsupported operation: " .. tostring(operation))
    end
end

return {handle = handle}

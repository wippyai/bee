-- MIT. Apply the resource owner's fenced attempt report through placement.
local bounds = require("bounds")
local funcs = require("funcs")
local M = {}
local STOP_ATTEMPT = "bee.placement.native.binding:stop_revoked"
type Object = {[string]: unknown}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}

function M.apply(reply: Reply, nested: boolean): Reply
    if not reply.ok then return reply end
    local value = bounds.object(reply.value)
    local report = value and (nested and bounds.object(value.revocation) or value) or nil
    local attempts = report and bounds.ids(report.fenced_attempts, true) or nil
    if not value or not attempts then
        return {ok = false, value = nil, error = {code = "STORAGE", message = "revocation report is malformed"}}
    end
    local stopped: {Object} = {}
    for _, attempt_id in ipairs(attempts) do
        local raw, call_error = funcs.call(STOP_ATTEMPT, {attempt_id = attempt_id})
        local result = bounds.object(raw)
        local failure = result and bounds.object(result.error) or nil
        stopped[#stopped + 1] = {attempt_id = attempt_id, stopped = result ~= nil and result.ok == true,
            state = result and result.ok == true and (bounds.object(result.value) or {}).execution_state or nil,
            error = call_error and "placement stop call failed" or (failure and failure.message or nil)}
    end
    value.stop_results = stopped
    return reply
end

return M

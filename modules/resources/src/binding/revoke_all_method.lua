-- MIT. Resource authority method revoke_all: the caller's actor, the linked store, one operation.
local authority = require("authority")
local bounds = require("bounds")
local funcs = require("funcs")
local STOP_ATTEMPT = "bee.placement.native.binding:stop_revoked"
type Object = {[string]: unknown}
local function handle(request: unknown): authority.Reply
    local reply = authority.revoke_all(request)
    if not reply.ok then return reply end
    local value = bounds.object(reply.value)
    local attempts = value and bounds.ids(value.fenced_attempts, true) or nil
    if not value or not attempts then return {ok = false, value = nil,
        error = {code = "STORAGE", message = "revocation report is malformed"}} end
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
return {handle = handle}

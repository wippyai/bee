-- MIT
local access = require("access")
local outbound = require("outbound")
local protocol = require("protocol")
local application = require("application")
local bounds = require("bounds")
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end
local function call(raw: unknown): Reply
    local caller, record, live, refusal = access.granted()
    if refusal then return refusal end
    local identity = bounds.object(caller)
    if not identity or not record then return fail("DENIED", "application identity is unavailable") end
    local binding, admitted, admission_error = application.admission(tostring(identity.definition_id), tostring(identity.workspace_id))
    if not binding then return fail("DENIED", "source application admission is absent or revoked: " .. tostring(admission_error)) end
    if admitted and admitted.overlay_owner ~= record.overlay_owner then return fail("DENIED", "source admission and grant ownership differ") end
    local request, err = outbound.authorize(raw, record, caller, live)
    if not request then return fail("DENIED", tostring(err)) end
    local reply, call_error = protocol.call(request.node, "application.call", request.args, request.timeout, true)
    if not reply then return fail("UNAVAILABLE", tostring(call_error)) end
    local value, result_error = outbound.result(reply)
    if result_error then return fail("FAILED", result_error) end
    return {ok = true, value = value, error = nil}
end
return {call = call}

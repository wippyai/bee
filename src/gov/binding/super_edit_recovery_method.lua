-- MIT. Host startup's one-way fallback to disable all super-edit overlays.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")

local M = {}
local BACKEND = "bee.gov.binding:super_edit_backend_call"
local EXECUTION_SCOPE = "bee.gov.security:super_edit_recovery_execution_scope"

function M.handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local caller = security.actor()
    if not request or bounds.fields(request, {"operation"}) or request.operation ~= "disable_all"
        or not caller or caller:id() ~= "bee.local"
        or not security.can("bee.gov.super_edit.recover", "host-startup") then
        return {ok = false, code = "DENIED", message = "boot fallback is available only to the native local host", replayed = false}
    end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then
        return {ok = false, code = "UNAVAILABLE", message = tostring(scope_error or "edit-mode recovery scope unavailable"), replayed = false}
    end
    local executor, executor_error = funcs.new():with_actor(security.new_actor("bee.gov.recovery")):with_scope(scope)
    if not executor then
        return {ok = false, code = "DENIED", message = tostring(executor_error or "edit-mode recovery scope denied"), replayed = false}
    end
    local result, call_error = executor:call(BACKEND, request)
    if call_error then return {ok = false, code = "UNAVAILABLE", message = tostring(call_error), replayed = false} end
    local reply = bounds.object(result)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then
        return {ok = false, code = "INTERNAL", message = "edit-mode recovery backend returned a malformed reply", replayed = false}
    end
    return reply
end

return M

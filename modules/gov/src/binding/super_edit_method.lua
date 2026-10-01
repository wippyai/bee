-- MIT. Person-facing facade for host activation profile changes.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")

local M = {}
local BACKEND = "bee.gov.binding:super_edit_backend_call"
local EXECUTION_SCOPE = "bee.gov.security:super_edit_execution_scope"

local function reply(value: unknown): {[string]: unknown}?
    local result = bounds.object(value)
    if not result or type(result.ok) ~= "boolean" or type(result.replayed) ~= "boolean" then return nil end
    return result
end

function M.handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local fields = request and bounds.fields(request, {"operation", "workspace_id", "input"}) or "request is invalid"
    local operation = request and bounds.id(request.operation) or nil
    local workspace_id = request and bounds.text(request.workspace_id, 32) or nil
    local actor = security.actor()
    local metadata = actor and actor:meta() or nil
    if fields or not request or (operation ~= "enable" and operation ~= "disable")
        or not workspace_id or #workspace_id ~= 32 or workspace_id:find("[^0-9a-f]")
        or not actor or type(metadata) ~= "table" or metadata.definition_id ~= "bee.settings.app:app" then
        return {ok = false, code = "DENIED", message = "edit mode is available only from Bee Settings", replayed = false}
    end
    if (operation == "enable" and (type(request.input) ~= "string" or #request.input > 1024))
        or (operation == "disable" and request.input ~= nil) then
        return {ok = false, code = "INVALID", message = "edit mode request is invalid", replayed = false}
    end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then
        return {ok = false, code = "UNAVAILABLE", message = tostring(scope_error or "edit mode scope unavailable"), replayed = false}
    end
    local executor, executor_error = funcs.new():with_actor(security.new_actor("bee.gov.super_edit")):with_scope(scope)
    if not executor then
        return {ok = false, code = "DENIED", message = tostring(executor_error or "edit mode scope denied"), replayed = false}
    end
    local result, call_error = executor:call(BACKEND, request)
    if call_error then return {ok = false, code = "UNAVAILABLE", message = tostring(call_error), replayed = false} end
    return reply(result) or {ok = false, code = "INTERNAL", message = "edit mode backend returned a malformed reply", replayed = false}
end

return M

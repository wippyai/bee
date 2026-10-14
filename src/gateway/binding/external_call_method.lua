-- SPDX-License-Identifier: MIT
local security = require("security")
local funcs = require("funcs")
local bounds = require("bounds")
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
local function failure(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end
local function handle(raw: unknown): Reply
    local request = bounds.object(raw)
    local actor = security.actor()
    local workspace = actor and bounds.id(actor:meta().workspace_id)
    local definition = actor and actor:meta().definition_id
    if not workspace or definition ~= "bee.gateway.app:app" or not security.can("bee.gateway.external.view", workspace) then
        return failure("DENIED", "External clients are managed through Sessions")
    end
    if not request or bounds.fields(request, {"operation", "client_id"}) then
        return failure("INVALID", "Invalid client operation")
    end
    local id = bounds.id(request.client_id)
    if request.operation ~= "list" and (not id or (request.operation ~= "revoke" and request.operation ~= "read")) then
        return failure("INVALID", "Unknown client operation")
    end
    local scope, scope_error = security.named_scope("bee.gateway.security:external_owner")
    if not scope then return failure("UNAVAILABLE", "External owner scope: " .. tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return failure("UNAVAILABLE", "External owner executor: " .. tostring(executor_error)) end
    local raw_reply, call_error = executor:call("bee.gateway.binding:external_backend", {
        operation = request.operation, client_id = id, workspace_id = workspace})
    if call_error then return failure("UNAVAILABLE", "External owner: " .. tostring(call_error)) end
    local reply = bounds.object(raw_reply)
    if not reply or type(reply.ok) ~= "boolean" then return failure("UNAVAILABLE", "External owner returned an invalid reply") end
    if reply.ok then return {ok = true, value = reply.value} end
    local fault = bounds.object(reply.error)
    return failure(fault and bounds.id(fault.code) or "FAILED", fault and bounds.text(fault.message, 4096) or "External owner refused the operation")
end
return {handle = handle}

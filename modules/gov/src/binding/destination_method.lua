-- MIT. Public destination review and activation facade. It authenticates the
-- caller's exact delivery operation before entering the private destination
-- scope, and presents an owner fault the way the application boundary names it
-- so a refusal arrives with its own code and reason.
local funcs = require("funcs")
local security = require("security")
local service = require("service")
local transaction = require("transaction")
local bounds = require("bounds")

type Result = transaction.Result

local function reply(result: Result): {[string]: unknown}
    if result.ok then return {ok = true, value = result.value, replayed = result.replayed == true} end
    return {ok = false, value = result.value, replayed = false,
        error = {code = result.code or "INTERNAL", message = result.message or "destination operation failed"}}
end

local function decode_reply(value: unknown): Result?
    local decoded = bounds.object(value)
    if not decoded then return nil end
    if type(decoded.ok) ~= "boolean" or type(decoded.replayed) ~= "boolean" then return nil end
    if decoded.code ~= nil and type(decoded.code) ~= "string" then return nil end
    if decoded.message ~= nil and type(decoded.message) ~= "string" then return nil end
    if decoded.commit ~= nil and type(decoded.commit) ~= "boolean" then return nil end
    return {ok = decoded.ok, code = decoded.code, message = decoded.message,
        value = decoded.value, replayed = decoded.replayed, commit = decoded.commit}
end

local function handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local action = request and service.required_action(request.operation) or nil
    local workspace_id = request and bounds.id(request.workspace_id) or nil
    if not request or not action then return reply(transaction.failure("INVALID", "destination request operation is invalid")) end
    if not workspace_id then return reply(transaction.failure("INVALID", "destination workspace is invalid")) end
    local actor = security.actor()
    if not actor or not security.can(action, workspace_id) then
        return reply(transaction.failure("DENIED", "destination operation is not authorized"))
    end
    local scope, scope_error = security.named_scope(service.SCOPE)
    if not scope then return reply(transaction.failure("UNAVAILABLE", tostring(scope_error or "destination execution scope unavailable"))) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return reply(transaction.failure("DENIED", tostring(executor_error or "destination execution scope denied"))) end
    local result, call_error = executor:call(service.BACKEND, request)
    if call_error then return reply(transaction.failure("UNAVAILABLE", tostring(call_error))) end
    local decoded = decode_reply(result)
    if not decoded then return reply(transaction.failure("INTERNAL", "destination backend returned a malformed reply")) end
    return reply(decoded)
end
return {handle = handle}

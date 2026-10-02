-- MIT. Publication enters its private storage scope only after exact caller authorization.
local service = require("service")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local transaction = require("transaction")
local function handle(raw: unknown): transaction.Result
    local request = bounds.object(raw)
    local action = request and service.required_action(request.operation) or nil
    local workspace = request and bounds.id(request.workspace_id) or nil
    if not request or not action or not workspace then
        return transaction.failure("INVALID", "publication request is invalid")
    end
    if not security.actor() or not security.can(action, workspace) then
        return transaction.failure("DENIED", "application publication is not authorized")
    end
    local scope, scope_error = security.named_scope(service.SCOPE)
    if not scope then return transaction.failure("UNAVAILABLE", tostring(scope_error)) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return transaction.failure("DENIED", tostring(executor_error)) end
    local raw_reply, call_error = executor:call(service.BACKEND, request)
    if call_error then return transaction.failure("UNAVAILABLE", tostring(call_error)) end
    local reply = bounds.object(raw_reply)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean"
        or (reply.code ~= nil and type(reply.code) ~= "string")
        or (reply.message ~= nil and type(reply.message) ~= "string")
        or (reply.commit ~= nil and type(reply.commit) ~= "boolean") then
        return transaction.failure("INTERNAL", "publication backend returned a malformed reply")
    end
    return {ok = reply.ok, code = reply.code, message = reply.message,
        value = reply.value, replayed = reply.replayed, commit = reply.commit}
end
local function backend(raw: unknown): transaction.Result
    if not security.can(service.EXECUTE, service.BACKEND) then
        return transaction.failure("DENIED", "publication backend is not authorized")
    end
    return service.call(raw)
end
return {handle = handle, backend = backend}

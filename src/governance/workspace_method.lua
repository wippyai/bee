-- MIT. Public authoring facade. It authenticates the caller's exact operation
-- before entering the fixed private storage scope; actor context is inherited.
local funcs = require("funcs")
local security = require("security")
local protocol = require("protocol")
local transaction = require("transaction")
local bounds = require("bounds")

local BACKEND = "bee.governance:workspace_backend_call"
local EXECUTION_SCOPE = "bee.governance:workspace_execution_scope"
type Result = transaction.Result

local function decode_reply(value: unknown): Result?
    local reply = bounds.object(value)
    if not reply then return nil end
    if type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then return nil end
    if reply.code ~= nil and type(reply.code) ~= "string" then return nil end
    if reply.message ~= nil and type(reply.message) ~= "string" then return nil end
    if reply.commit ~= nil and type(reply.commit) ~= "boolean" then return nil end
    return {ok = reply.ok, code = reply.code, message = reply.message,
        value = reply.value, replayed = reply.replayed, commit = reply.commit}
end

local function handle(raw: unknown): Result
    local request, invalid = protocol.decode(raw)
    if not request then return transaction.failure("INVALID", invalid or "invalid workspace request") end
    local actor = security.actor()
    local action = (request.operation == "read" or request.operation == "list")
        and "bee.governance.workspace.read" or "bee.governance.workspace.write"
    if not actor or not security.can(action, request.workspace_id) then
        return transaction.failure("DENIED", "workspace operation is not authorized")
    end
    local scope, scope_error = security.named_scope(EXECUTION_SCOPE)
    if not scope then return transaction.failure("UNAVAILABLE", tostring(scope_error or "workspace execution scope unavailable")) end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return transaction.failure("DENIED", tostring(executor_error or "workspace execution scope denied")) end
    local result, call_error = executor:call(BACKEND, request)
    if call_error then return transaction.failure("UNAVAILABLE", tostring(call_error)) end
    local reply = decode_reply(result)
    if not reply then return transaction.failure("INTERNAL", "workspace backend returned a malformed reply") end
    return reply
end
return {handle = handle}

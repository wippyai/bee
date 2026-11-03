local contract = require("contract")
local ctx = require("ctx")
local bounds = require("bounds")
local protocol = require("protocol")
local M = {}
local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}}
end
-- call: the profile MCP tool's get, list or put in the bound workspace; the
-- workspace is host owned and never an argument.
function M.call(raw: unknown): {[string]: unknown}
    local arguments = bounds.object(raw)
    if not arguments then return fail("INVALID", "profile arguments must be an object") end
    if not bounds.member(arguments.operation, {"get", "list", "put"}) then return fail("INVALID", "operation must be get, list or put") end
    if arguments.workspace_id ~= nil then return fail("INVALID", "profile workspace is host owned") end
    local request: {[string]: unknown} = {}
    for key, value in pairs(arguments) do request[key] = value end
    request.workspace_id = ctx.get("bee.workspace_id")
    local decoded, err = protocol.decode(request)
    if not decoded then return fail("INVALID", err or "invalid profile request") end
    local owner, open_error = contract.get("bee.harness:profiles")
    if not owner then return fail("UNAVAILABLE", tostring(open_error)) end
    local instance, failure = owner:open("bee.harness.binding:profiles_local")
    if not instance then return fail("UNAVAILABLE", tostring(failure)) end
    local reply, call_error = instance:call(request)
    return bounds.object(reply) or fail("UNAVAILABLE", tostring(call_error))
end
return M

-- MIT. What a governed app does with Sessions: resolve the public contract,
-- open the owner binding and call it, the actions the client library takes.
-- The suite makes fake owners the contracts' defaults, so the probe names the
-- real owner bindings the client library resolves on a node.
local contract = require("contract")
local bounds = require("bounds")

local BINDINGS = {["bee.threads.sessions:contract"] = "bee.threads.sessions.binding:owner_binding",
    ["bee.threads.sessions:catalog"] = "bee.threads.sessions.binding:catalog_binding"}

local function call(id: string, method: string, request: {[string]: unknown}): {[string]: unknown}
    local definition, get_error = contract.get(id)
    if not definition then return {ok = false, code = "TRANSPORT", message = tostring(get_error)} end
    local instance, open_error = definition:open(BINDINGS[id])
    if not instance then return {ok = false, code = "TRANSPORT", message = tostring(open_error)} end
    local entry = (instance)[method]
    local raw, call_error = (entry)(instance, request)
    if call_error ~= nil then return {ok = false, code = "TRANSPORT", message = tostring(call_error)} end
    local reply = bounds.object(raw)
    local fault = reply and bounds.object(reply.error)
    return {ok = reply ~= nil and reply.ok == true, code = fault and fault.code, message = fault and fault.message}
end

local function handle(request: {op: string, definition: string?, operation_key: string?}): {[string]: unknown}
    if request.op == "catalog" then return call("bee.threads.sessions:catalog", "list", {}) end
    if request.op == "list" then return call("bee.threads.sessions:contract", "list", {}) end
    return call("bee.threads.sessions:contract", "open", {spec = {definition = request.definition}, operation_key = request.operation_key})
end

return {handle = handle}

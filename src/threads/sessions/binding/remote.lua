-- MIT
local hive = require("hive")
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.call(node: string, operation: string, arguments: Object): Object
    local workspace: string? = nil
    local spec, filter = bounds.object(arguments.spec), bounds.object(arguments.filter)
    if spec then workspace = bounds.id(spec.workspace) end
    if filter then workspace = bounds.id(filter.workspace) or workspace end
    for _, field in ipairs({"session", "work", "subject", "operation"}) do
        local ref = arguments[field]
        if type(ref) == "string" then workspace = ref:match("^[a-z]+:[^:]+:([^:]+):[^:]+$") or workspace end
    end
    local result, err, code = hive.call({node = node, workspace_id = workspace, application = "bee.harness.app:app", service = "sessions",
        operation = operation, arguments = arguments, idempotency_key = arguments.operation_key})
    if err then return {ok = false, error = {code = code or "UNKNOWN_OUTCOME", message = err,
        retry = (code == "DENIED" or code == "INVALID") and "never" or arguments.operation_key and "same_key" or "refresh", operation_key = arguments.operation_key}} end
    return assert(bounds.object(result))
end
return M

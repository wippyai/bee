-- MIT
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.node(raw: unknown): (string?, string?)
    if raw == nil then return nil, nil end
    local node = bounds.id(raw)
    if not node or node == "*" then return nil, "node must be a bounded node identifier" end
    return node, nil
end
function M.decode(raw: unknown): (Object?, string?)
    local value = bounds.object(raw == nil and {} or raw)
    if not value then return nil, "request must be an object" end
    local extra = bounds.fields(value, {"node", "operation", "tool", "arguments", "idempotency_key"})
    if extra then return nil, extra end
    local node, node_error = M.node(value.node)
    if node_error then return nil, node_error end
    local operation = value.operation == nil and "list" or bounds.member(value.operation, {"list", "call"})
    if not operation then return nil, "operation must be list or call" end
    local request: Object = {operation = operation, node = node}
    if operation == "list" then
        if value.tool ~= nil or value.arguments ~= nil or value.idempotency_key ~= nil then return nil, "list takes only node" end
    else
        local tool = bounds.line(value.tool, 64)
        local arguments = bounds.object(value.arguments == nil and {} or value.arguments)
        local key = value.idempotency_key == nil and nil or bounds.line(value.idempotency_key, 128)
        if not tool or not arguments or (value.idempotency_key ~= nil and not key) then return nil, "call takes tool, arguments and an optional bounded idempotency key" end
        request.tool, request.arguments, request.idempotency_key = tool, arguments, key
    end
    return request, nil
end
return M

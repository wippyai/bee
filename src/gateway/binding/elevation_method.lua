-- MIT. Gateway method elevation: request one catalog capability or poll its
-- decision, as the caller's actor through the linked store.
local gateway = require("gateway")
local bounds = require("bounds")
local function handle(request: unknown): gateway.Reply
    local object = bounds.object(request)
    local operation = object and object.operation
    if operation == "request" then return gateway.request_capability(request) end
    if operation == "status" then return gateway.capability_status(request) end
    return {ok = false, value = nil, error = {code = "INVALID", message = "operation must be request or status"}}
end
return {handle = handle}

-- MIT. Gateway method request_capability: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.request_capability(request)
end
return {handle = handle}

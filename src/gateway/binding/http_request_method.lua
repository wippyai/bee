-- MIT. Gateway method http_request: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.http_request(request)
end
return {handle = handle}

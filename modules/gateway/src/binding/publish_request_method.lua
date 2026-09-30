-- MIT. Gateway method publish_request: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.publish("request", request)
end
return {handle = handle}

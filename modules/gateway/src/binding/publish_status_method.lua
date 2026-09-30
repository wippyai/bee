-- MIT. Gateway method publish_status: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.publish("status", request)
end
return {handle = handle}

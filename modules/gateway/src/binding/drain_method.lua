-- MIT. Gateway method drain: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.drain(request)
end
return {handle = handle}

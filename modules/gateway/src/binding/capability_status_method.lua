-- MIT. Gateway method capability_status: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.capability_status(request)
end
return {handle = handle}

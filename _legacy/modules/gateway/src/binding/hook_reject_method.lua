-- MIT. Gateway method hook_reject: the caller's actor, the linked store, one intake operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.hook_reject(request)
end
return {handle = handle}

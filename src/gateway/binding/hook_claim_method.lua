-- MIT. Gateway method hook_claim: the caller's actor, the linked store, one intake operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.hook_claim(request)
end
return {handle = handle}

-- MIT. Gateway method renew_attempt: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.renew_attempt(request)
end
return {handle = handle}

-- MIT. Gateway method forget_session: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.forget_session(request)
end
return {handle = handle}

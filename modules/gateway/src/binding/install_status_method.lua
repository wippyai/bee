-- MIT. Gateway method install_status: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.install_status(request)
end
return {handle = handle}

-- MIT. Gateway method uninstall_request: the caller's actor, the linked store, one operation.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.uninstall_request(request)
end
return {handle = handle}

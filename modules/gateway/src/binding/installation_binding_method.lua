-- MIT. Resolve a persisted installation request to its gateway-owned attempt binding.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.installation_binding(request)
end
return {handle = handle}

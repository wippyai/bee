-- MIT. Resolve a persisted effect request to its gateway-owned attempt binding.
local gateway = require("gateway")
local function handle(request: unknown): gateway.Reply
    return gateway.effect_binding(request)
end
return {handle = handle}

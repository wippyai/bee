-- MIT. Driver method prepare for native Wippy driver: a declarative launch specification.
local bounds = require("bounds")

local function handle(request: unknown): {[string]: unknown}
    local object = bounds.object(request)
    if not object then return {ok = false, error = "request must be an object"} end
    local launch = {
        executable = "bee-wippy",
        argv = {},
        environment = {},
        readiness = "immediate",
    }
    return {ok = true, launch = launch}
end

return {handle = handle}

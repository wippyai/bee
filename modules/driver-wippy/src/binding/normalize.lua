-- MIT. Driver method normalize for native Wippy driver: turn one protocol envelope into observations and terminal report.
local bounds = require("bounds")

local function handle(request: unknown): {[string]: unknown}
    local object = bounds.object(request)
    if not object then return {ok = false, error = "request must be an object"} end
    local state = bounds.object(object.state) or {}
    return {
        ok = true,
        state = state,
        observations = {},
        terminal = nil,
    }
end

return {handle = handle}

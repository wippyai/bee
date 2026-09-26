-- MIT. Driver method configure for native Wippy driver.
local bounds = require("bounds")

local function handle(value: unknown): {[string]: unknown}
    local object = bounds.object(value)
    if not object then return {ok = false, error = "request must be an object"} end
    return {
        ok = true,
        delivery = {
            arguments = {},
            files = {},
        },
    }
end

return {handle = handle}

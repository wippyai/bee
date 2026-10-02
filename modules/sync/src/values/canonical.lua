-- MIT. Sync applies its wire limits to the shared canonical JSON encoder.
local bounds = require("bounds")
local encoder = require("encoder")
local M = {}

function M.encode(value: unknown, maximum_raw: unknown?): (string?, string?)
    local maximum = bounds.capacity(maximum_raw, bounds.MAX_JSON_BYTES, 16777216)
    if not maximum then return nil, "encoded size bound is invalid" end
    return encoder.encode(value, maximum, bounds.MAX_DEPTH)
end

return M

-- MIT. Sync capacities for durable feeds and their wire values.
local bounds = require("bounds")
local M = {}
M.MAX_JSON_BYTES = 16384
M.MAX_EVENTS = 1024
M.MAX_RECEIPTS = 8192
M.MAX_PAGE = 128

function M.capacity(value: unknown, fallback: integer, maximum: integer): integer?
    if value == nil then return fallback end
    local number = bounds.integer(value)
    if not number or number < 1 or number > maximum then return nil end
    return number
end

return M

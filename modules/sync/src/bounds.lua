-- MIT. Sync capacities for durable feeds and SQLite checks. Generic value
-- validation is owned by bee.values.
local M = {}
local values = require("values")
M.MAX_JSON_BYTES = 16384
M.MAX_EVENTS = 1024
M.MAX_RECEIPTS = 8192
M.MAX_PAGE = 128
M.MAX_DEPTH = 24
function M.capacity(value: unknown, fallback: integer, maximum: integer): integer?
    if value == nil then return fallback end
    local number = values.integer(value)
    if not number or number < 1 or number > maximum then return nil end
    return number
end
return M

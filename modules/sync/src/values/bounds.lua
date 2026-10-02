-- MIT. Bounds shared by the durable feed envelope and SQLite checks. Feed
-- adapters validate their own typed payloads before this generic store sees
-- them.
local M = {}
local shared = require("shared")
M.MAX_ID_BYTES = shared.MAX_ID_BYTES
M.MAX_JSON_BYTES = 16384
M.MAX_EVENTS = 1024
M.MAX_RECEIPTS = 8192
M.MAX_PAGE = 128
M.MAX_DEPTH = 24
function M.id(value: unknown): string?
    return shared.id(value)
end
function M.count(value: unknown, maximum: integer): integer?
    local number = shared.integer(value)
    if not number or number < 0 or number > maximum then return nil end
    return number
end
function M.capacity(value: unknown, fallback: integer, maximum: integer): integer?
    if value == nil then return fallback end
    local number = shared.integer(value)
    if not number or number < 1 or number > maximum then return nil end
    return number
end
return M

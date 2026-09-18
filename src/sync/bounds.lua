-- MIT. Bounds shared by the durable feed envelope and SQLite checks. Feed
-- adapters validate their own typed payloads before this generic store sees
-- them.
local M = {}
M.MAX_ID_BYTES = 160
M.MAX_JSON_BYTES = 16384
M.MAX_EVENTS = 1024
M.MAX_RECEIPTS = 8192
M.MAX_PAGE = 128
M.MAX_DEPTH = 24
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value ~= value then return nil end
    if value > 9007199254740991 or value < -9007199254740991 then return nil end
    return math.floor(value)
end
function M.id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES or value:find("%c") then return nil end
    return value
end
function M.count(value: unknown, maximum: integer): integer?
    local number = integer(value)
    if not number or number < 0 or number > maximum then return nil end
    return number
end
function M.capacity(value: unknown, fallback: integer, maximum: integer): integer?
    if value == nil then return fallback end
    local number = integer(value)
    if not number or number < 1 or number > maximum then return nil end
    return number
end
return M

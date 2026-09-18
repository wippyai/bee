-- MIT. Shared bounds and primitive decoders of the Hive protocol. Every
-- envelope decoder reads identifiers, objects and lists through these.
local M = {}
M.MAX_ID_BYTES = 160
M.MAX_LIST_ITEMS = 64
function M.id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES or value:find("%c") then return nil end
    return value
end
function M.object(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" then return nil end
    end
    return value :: {[string]: unknown}
end
function M.fields(value: {[string]: unknown}, allowed: {string}): string?
    local permitted: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do permitted[name] = true end
    for key in pairs(value) do
        if not permitted[key] then return "unknown field " .. key end
    end
    return nil
end
function M.integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
function M.timestamp(value: unknown): string?
    if type(value) ~= "string" or not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$") then return nil end
    return value
end
function M.ids(value: unknown): ({string}?, string?)
    if type(value) ~= "table" then return nil, "expected a list" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "list keys must be dense" end
        count = count + 1
    end
    if count > M.MAX_LIST_ITEMS then return nil, "list exceeds " .. tostring(M.MAX_LIST_ITEMS) .. " items" end
    local result: {string} = {}
    for index = 1, count do
        local item = M.id(value[index])
        if not item then return nil, "list item " .. tostring(index) .. " is not an identifier" end
        result[index] = item
    end
    return result, nil
end
function M.optional_id(value: {[string]: unknown}, name: string): (string?, boolean)
    local raw: unknown = value[name]
    if raw == nil then return nil, true end
    local result = M.id(raw)
    if not result then return nil, false end
    return result, true
end
-- One line of bounded text: nonempty, no control characters.
function M.line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > limit or value:find("%c") then return nil end
    return value
end
return M

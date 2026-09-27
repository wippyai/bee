-- Shared primitive decoders for Bee protocol values.
local M = {}
M.MAX_ID_BYTES = 160
M.MAX_ARRAY_ITEMS = 64
M.MAX_TEXT_BYTES = 16384
M.MAX_SUBPATH_BYTES = 512

function M.id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES or value:find("%c") then return nil end
    return value
end

function M.text(value: unknown, limit: integer?): string?
    if type(value) ~= "string" or #value > (limit or M.MAX_TEXT_BYTES) then return nil end
    return value
end

function M.line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > limit or value:find("%c") then return nil end
    return value
end

function M.integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value ~= value
        or value > 9007199254740991 or value < -9007199254740991 then return nil end
    return math.floor(value)
end

function M.count(value: unknown): integer?
    local number = M.integer(value)
    if not number or number < 0 then return nil end
    return number
end

function M.timestamp(value: unknown): string?
    if type(value) ~= "string" or #value ~= 24 or not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$") then return nil end
    local month, day, hour, minute, second = tonumber(value:sub(6, 7)), tonumber(value:sub(9, 10)),
        tonumber(value:sub(12, 13)), tonumber(value:sub(15, 16)), tonumber(value:sub(18, 19))
    if not month or not day or not hour or not minute or not second then return nil end
    if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59 then return nil end
    return value
end

function M.array(value: unknown, limit: integer?): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, "expected a list" end
    local maximum = limit or M.MAX_ARRAY_ITEMS
    if maximum < 0 then return nil, "list exceeds its bound" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "list keys must be dense" end
        count = count + 1
        if count > maximum then return nil, "list exceeds " .. tostring(maximum) .. " items" end
    end
    for index = 1, count do if value[index] == nil then return nil, "list keys must be dense" end end
    return value :: {unknown}, nil
end

function M.ids(value: unknown, distinct: boolean?): ({string}?, string?)
    local rows, array_error = M.array(value, M.MAX_ARRAY_ITEMS)
    if not rows then return nil, array_error end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for index, raw in ipairs(rows) do
        local item = M.id(raw)
        if not item then return nil, "list item " .. tostring(index) .. " is not an identifier" end
        if distinct == true and seen[item] then return nil, "list item " .. tostring(index) .. " repeats" end
        seen[item] = true
        result[index] = item
    end
    return result, nil
end

function M.fields(value: {[string]: unknown}, allowed: {string}): string?
    local permitted: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do permitted[name] = true end
    for key in pairs(value) do
        if type(key) ~= "string" or not permitted[key] then return "unknown field " .. tostring(key) end
    end
    return nil
end

function M.object(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: {[string]: unknown}
end

function M.optional_id(value: {[string]: unknown}, name: string): (string?, boolean)
    local raw: unknown = value[name]
    if raw == nil then return nil, true end
    local result = M.id(raw)
    if not result then return nil, false end
    return result, true
end

function M.subpath(value: unknown): (string?, string?)
    if type(value) ~= "string" then return nil, "subpath must be a string" end
    if #value > M.MAX_SUBPATH_BYTES then return nil, "subpath is too long" end
    if value == "" then return "", nil end
    if value:sub(1, 1) == "/" or value:find("\\", 1, true) or value:find("\0", 1, true) then return nil, "subpath must be relative" end
    for segment in (value .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then return nil, "subpath has an invalid segment" end
    end
    return value, nil
end

return M

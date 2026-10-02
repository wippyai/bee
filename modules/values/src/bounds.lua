-- Shared primitive decoders for Bee protocol values.
local clock = require("clock")
local M = {}
M.MAX_SAFE_INTEGER = 9007199254740991
M.MAX_ID_BYTES = 160
M.MAX_ARRAY_ITEMS = 64
M.MAX_TEXT_BYTES = 16384
M.MAX_SUBPATH_BYTES = 512
type RelativePathOptions = {nonempty: boolean?, no_control: boolean?}

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
        or value > M.MAX_SAFE_INTEGER or value < -M.MAX_SAFE_INTEGER then return nil end
    return math.floor(value)
end

function M.count(value: unknown, maximum: integer?): integer?
    local number = M.integer(value)
    if not number or number < 0 or (maximum ~= nil and number > maximum) then return nil end
    return number
end

function M.member(value: unknown, variants: {string}): string?
    if type(value) ~= "string" then return nil end
    for _, variant in ipairs(variants) do if variant == value then return value end end
    return nil
end

function M.timestamp(value: unknown): string?
    if type(value) ~= "string" or not clock.parse(value) then return nil end
    return value
end

function M.array(value: unknown, limit: integer?, label: string?): ({unknown}?, string?)
    local invalid_list = label and label .. " must be a dense list" or "list keys must be dense"
    if type(value) ~= "table" then return nil, label and invalid_list or "expected a list" end
    local maximum = limit or M.MAX_ARRAY_ITEMS
    if maximum < 0 then return nil, "list exceeds its bound" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, invalid_list end
        count = count + 1
        if count > maximum then
            return nil, label and label .. " exceeds " .. tostring(maximum) .. " items"
                or "list exceeds " .. tostring(maximum) .. " items"
        end
    end
    local result: {unknown} = {}
    for index = 1, count do
        local item = value[index]
        if item == nil then return nil, invalid_list end
        result[index] = item
    end
    return result, nil
end

function M.dense_list(value: unknown, maximum: integer, label: string): ({unknown}?, string?)
    return M.array(value, maximum, label)
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
    return value
end

function M.optional_id(value: {[string]: unknown}, name: string): (string?, boolean)
    local raw: unknown = value[name]
    if raw == nil then return nil, true end
    local result = M.id(raw)
    if not result then return nil, false end
    return result, true
end

function M.subpath(value: unknown, maximum: integer?, options: RelativePathOptions?): (string?, string?)
    if type(value) ~= "string" then return nil, "subpath must be a string" end
    local limit = maximum or M.MAX_SUBPATH_BYTES
    local rules = options or {}
    if #value > limit then return nil, "subpath is too long" end
    if value == "" then
        if rules.nonempty then return nil, "subpath must not be empty" end
        return "", nil
    end
    if value:sub(1, 1) == "/" or value:find("\\", 1, true) or value:find("\0", 1, true)
        or (rules.no_control == true and value:find("%c")) then return nil, "subpath must be relative" end
    for segment in (value .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then return nil, "subpath has an invalid segment" end
    end
    return value, nil
end

return M

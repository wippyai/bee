-- MIT. Canonical JSON for plain Lua values: sorted keys, no whitespace, and
-- an optional byte budget enforced before each encoded fragment is allocated.
-- Empty tables retain the runtime JSON module's list-or-map shape.
local json = require("json")
local M = {}
M.MAX_DEPTH = 32

type Output = {parts: {string}, bytes: integer, maximum_bytes: integer?}

local function append(output: Output, value: string): boolean
    local bytes = output.bytes + #value
    if output.maximum_bytes and bytes > output.maximum_bytes then return false end
    output.parts[#output.parts + 1] = value
    output.bytes = bytes
    return true
end

local function escaped(value: string, output: Output): string?
    local size = 2
    for index = 1, #value do
        local byte = value:byte(index)
        if byte == 34 or byte == 92 then size = size + 2
        elseif byte < 32 then size = size + 6
        else size = size + 1 end
    end
    if output.maximum_bytes and output.bytes + size > output.maximum_bytes then return nil end
    local body = value:gsub('[%c"\\]', function(char: string): string
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. body .. '"'
end

local function encode_string(value: string, output: Output): boolean
    local encoded = escaped(value, output)
    return encoded ~= nil and append(output, encoded)
end

local function encode_value(value: unknown, depth: integer, maximum_depth: integer, output: Output): (boolean, string?)
    if depth > maximum_depth then return false, "value nests deeper than " .. tostring(maximum_depth) end
    if value == nil then return append(output, "null"), "value exceeds the encoded byte bound" end
    if type(value) == "boolean" then return append(output, value and "true" or "false"), "value exceeds the encoded byte bound" end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return false, "number is not finite" end
        local encoded: string
        if value == math.floor(value) and math.abs(value) < 9007199254740992 then
            encoded = string.format("%d", math.floor(value))
        else
            encoded = string.format("%.17g", value)
        end
        return append(output, encoded), "value exceeds the encoded byte bound"
    end
    if type(value) == "string" then
        if not encode_string(value, output) then return false, "value exceeds the encoded byte bound" end
        return true, nil
    end
    if type(value) ~= "table" then return false, "value is not encodable" end
    if next(value) == nil then
        local shape, shape_error = json.encode(value)
        if type(shape) ~= "string" then return false, tostring(shape_error or "cannot read empty table shape") end
        return append(output, shape), "value exceeds the encoded byte bound"
    end

    local count = 0
    local keys: {string} = {}
    for key in pairs(value) do
        count = count + 1
        if type(key) == "string" then
            keys[#keys + 1] = key
        elseif type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return false, "table key is not encodable"
        end
    end
    if #keys > 0 and #keys ~= count then return false, "table mixes list and object keys" end
    if #keys == 0 then
        if not append(output, "[") then return false, "value exceeds the encoded byte bound" end
        for index = 1, count do
            if value[index] == nil then return false, "list is not dense" end
            if index > 1 and not append(output, ",") then return false, "value exceeds the encoded byte bound" end
            local ok, item_error = encode_value(value[index], depth + 1, maximum_depth, output)
            if not ok then return false, item_error end
        end
        if not append(output, "]") then return false, "value exceeds the encoded byte bound" end
        return true, nil
    end

    table.sort(keys)
    if not append(output, "{") then return false, "value exceeds the encoded byte bound" end
    for index, key in ipairs(keys) do
        if index > 1 and not append(output, ",") then return false, "value exceeds the encoded byte bound" end
        if not encode_string(key, output) or not append(output, ":") then
            return false, "value exceeds the encoded byte bound"
        end
        local ok, item_error = encode_value(value[key], depth + 1, maximum_depth, output)
        if not ok then return false, item_error end
    end
    if not append(output, "}") then return false, "value exceeds the encoded byte bound" end
    return true, nil
end

function M.empty_like(value: unknown): {[unknown]: unknown}
    if type(value) == "table" and next(value) == nil then
        local shape = json.encode(value)
        if shape == "{}" then return table.create(0, 1) end
    end
    return table.create(1, 0)
end

function M.encode(value: unknown, maximum_bytes: integer?, maximum_depth: integer?): (string?, string?)
    if maximum_bytes ~= nil and maximum_bytes < 0 then return nil, "encoded byte bound is invalid" end
    if maximum_depth ~= nil and maximum_depth < 1 then return nil, "maximum depth is invalid" end
    local output: Output = {parts = {}, bytes = 0, maximum_bytes = maximum_bytes}
    local ok, encode_error = encode_value(value, 1, maximum_depth or M.MAX_DEPTH, output)
    if not ok then return nil, encode_error end
    return table.concat(output.parts), nil
end

return M

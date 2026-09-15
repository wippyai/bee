-- MIT. Canonical JSON for plain Lua values: sorted keys, no whitespace, so
-- equal requests and replies compare byte for byte. Dense integer-keyed
-- tables encode as arrays; an empty table encodes as an empty object.
local M = {}
local MAX_DEPTH = 32
local function encode_string(value: string): string
    local escaped = value:gsub('[%c"\\]', function(char: string): string
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end
local function encode_value(value: unknown, depth: integer): (string?, string?)
    if depth > MAX_DEPTH then return nil, "value nests deeper than " .. tostring(MAX_DEPTH) end
    if value == nil then return "null", nil end
    if type(value) == "boolean" then return value and "true" or "false", nil end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "number is not finite" end
        if value == math.floor(value) and math.abs(value) < 9007199254740992 then return string.format("%d", math.floor(value)), nil end
        return string.format("%.17g", value), nil
    end
    if type(value) == "string" then return encode_string(value), nil end
    if type(value) ~= "table" then return nil, "value is not encodable" end
    local count = 0
    local keys: {string} = {}
    local dense = true
    for key in pairs(value) do
        count = count + 1
        if type(key) == "string" then
            keys[#keys + 1] = key
        elseif type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "table key is not encodable"
        end
    end
    if #keys > 0 and #keys ~= count then return nil, "table mixes list and object keys" end
    if #keys == 0 and count > 0 then
        local parts: {string} = {}
        for index = 1, count do
            local item: unknown = value[index]
            if item == nil then dense = false break end
            local encoded, encode_error = encode_value(item, depth + 1)
            if not encoded then return nil, encode_error end
            parts[index] = encoded
        end
        if not dense then return nil, "list is not dense" end
        return "[" .. table.concat(parts, ",") .. "]", nil
    end
    table.sort(keys)
    local parts: {string} = {}
    for index, key in ipairs(keys) do
        local encoded, encode_error = encode_value(value[key], depth + 1)
        if not encoded then return nil, encode_error end
        parts[index] = encode_string(key) .. ":" .. encoded
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end
function M.encode(value: unknown): (string?, string?)
    return encode_value(value, 1)
end
return M

-- MIT. Canonical JSON makes an idempotency replay compare the complete
-- request byte for byte. This is deliberately local so sync does not depend
-- on the thread authority subsystem.
local bounds = require("bounds")
local M = {}
local function encode_string(value: string): string
    return '"' .. value:gsub('[%c"\\]', function(char: string): string
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end
local function encode(value: unknown, depth: integer): (string?, string?)
    if depth > bounds.MAX_DEPTH then return nil, "value nests too deeply" end
    if value == nil then return "null", nil end
    if type(value) == "boolean" then return value and "true" or "false", nil end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil, "number is not finite" end
        if value == math.floor(value) and math.abs(value) < 9007199254740992 then return string.format("%d", math.floor(value)), nil end
        return string.format("%.17g", value), nil
    end
    if type(value) == "string" then return encode_string(value), nil end
    if type(value) ~= "table" then return nil, "value is not encodable" end
    local total = 0
    local strings: {string} = {}
    for key in pairs(value) do
        total = total + 1
        if type(key) == "string" then
            strings[#strings + 1] = key
        elseif type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "table key is not encodable"
        end
    end
    if #strings > 0 and #strings ~= total then return nil, "table mixes list and object keys" end
    local parts: {string} = {}
    if #strings == 0 and total > 0 then
        for index = 1, total do
            if value[index] == nil then return nil, "list is not dense" end
            local item, item_error = encode(value[index], depth + 1)
            if not item then return nil, item_error end
            parts[index] = item
        end
        return "[" .. table.concat(parts, ",") .. "]", nil
    end
    table.sort(strings)
    for index, key in ipairs(strings) do
        local item, item_error = encode(value[key], depth + 1)
        if not item then return nil, item_error end
        parts[index] = encode_string(key) .. ":" .. item
    end
    return "{" .. table.concat(parts, ",") .. "}", nil
end
function M.encode(value: unknown): (string?, string?)
    local encoded, encode_error = encode(value, 1)
    if not encoded then return nil, encode_error end
    if #encoded > bounds.MAX_JSON_BYTES then return nil, "value is too large" end
    return encoded, nil
end
return M

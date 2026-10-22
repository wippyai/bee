-- MIT. Canonical JSON for plain Lua values: sorted keys, no whitespace, and
-- an optional byte budget enforced before each encoded fragment is allocated.
-- Empty tables retain the runtime JSON module's list-or-map shape.
local json = require("json")
local hash = require("hash")
local M = {}
M.MAX_DEPTH = 32

type Output = {parts: {string}, chunks: {string}, bytes: integer, maximum_bytes: integer?}

local function append(output: Output, value: string): boolean
    local bytes = output.bytes + #value
    if output.maximum_bytes and bytes > output.maximum_bytes then return false end
    output.parts[#output.parts + 1] = value
    output.bytes = bytes
    if #output.parts == 128 then
        output.chunks[#output.chunks + 1] = table.concat(output.parts)
        output.parts = {}
    end
    return true
end

local ESCAPES: {[string]: string} = {['"'] = '\\"', ['\\'] = '\\\\'}
for byte = 0, 31 do ESCAPES[string.char(byte)] = string.format("\\u%04x", string.char(byte):byte()) end
ESCAPES[string.char(127)] = "\\u007f"

local function encode_string(value: string, output: Output, suffix: string?): boolean
    local ending = suffix or ""
    if output.maximum_bytes then
        local bytes = output.bytes + #value + 2 + #ending
        if bytes > output.maximum_bytes then return false end
        local first = 1
        while first <= #value do
            local index = value:find('[%c"\\]', first)
            if not index then break end
            local byte = value:byte(index)
            bytes = bytes + ((byte == 34 or byte == 92) and 1 or 5)
            if bytes > output.maximum_bytes then return false end
            first = index + 1
        end
    end
    return append(output, '"' .. value:gsub('[%c"\\]', ESCAPES) .. '"' .. ending)
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
        if not encode_string(key, output, ":") then
            return false, "value exceeds the encoded byte bound"
        end
        local ok, item_error = encode_value(value[key], depth + 1, maximum_depth, output)
        if not ok then return false, item_error end
    end
    if not append(output, "}") then return false, "value exceeds the encoded byte bound" end
    return true, nil
end

-- A fresh empty table with the list-or-map shape of an empty value; any
-- other value yields an empty list.
-- empty_like returns an empty table that encodes with the JSON shape of an
-- empty value: {} for an object, [] otherwise. table.create carries the shape
-- hint; the table holds no entries, so it types as an empty map.
function M.empty_like(value: unknown): {[string]: unknown}
    if type(value) == "table" and next(value) == nil then
        local shape = json.encode(value)
        if shape == "{}" then return table.create(0, 1) :: {[string]: unknown} end
    end
    return table.create(1, 0) :: {[string]: unknown}
end

function M.encode(value: unknown, maximum_bytes: integer?, maximum_depth: integer?): (string?, string?)
    if maximum_bytes ~= nil and maximum_bytes < 0 then return nil, "encoded byte bound is invalid" end
    if maximum_depth ~= nil and maximum_depth < 1 then return nil, "maximum depth is invalid" end
    local output: Output = {parts = {}, chunks = {}, bytes = 0, maximum_bytes = maximum_bytes}
    local ok, encode_error = encode_value(value, 1, maximum_depth or M.MAX_DEPTH, output)
    if not ok then return nil, encode_error end
    if #output.parts > 0 then output.chunks[#output.chunks + 1] = table.concat(output.parts) end
    return table.concat(output.chunks), nil
end

function M.digest(value: unknown): (string?, string?)
    local encoded, encode_error = M.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
return M

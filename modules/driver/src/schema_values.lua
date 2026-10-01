-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Value = string | number | boolean | {[string]: unknown} | {unknown}
function M.decode(raw_schema: unknown, raw: unknown, label: string, depth: integer?): (Value?, string?)
    local schema = bounds.object(raw_schema)
    local nesting = depth or 0
    if not schema or nesting > 8 then return nil, label .. ": invalid or overnested value schema" end
    if schema.enum ~= nil then
        local choices = bounds.array(schema.enum, 32)
        if not choices then return nil, label .. ": invalid enum schema" end
        for _, choice in ipairs(choices) do
            if raw == choice and (type(raw) == "string" or type(raw) == "boolean" or type(raw) == "number") then return raw, nil end
        end
        return nil, label .. ": value is outside the declared enum"
    end
    if schema.type == "string" then
        local value = bounds.text(raw, bounds.count(schema.maxLength) or 4096)
        if not value or value:find("%z") then return nil, label .. ": expected bounded text" end
        return value, nil
    elseif schema.type == "boolean" then
        if type(raw) == "boolean" then return raw, nil end
    elseif schema.type == "number" or schema.type == "integer" then
        if type(raw) == "number" and raw == raw and math.abs(raw) <= bounds.MAX_SAFE_INTEGER
            and (schema.type ~= "integer" or raw == math.floor(raw))
            and (type(schema.minimum) ~= "number" or raw >= schema.minimum)
            and (type(schema.maximum) ~= "number" or raw <= schema.maximum) then return raw, nil end
    elseif schema.type == "array" then
        local rows = bounds.array(raw, math.floor(math.min(bounds.count(schema.maxItems) or 64, 64)))
        if not rows then return nil, label .. ": expected bounded dense array" end
        local result: {unknown} = {}
        for index, item in ipairs(rows) do
            local value, err = M.decode(schema.items, item, label .. "[" .. tostring(index) .. "]", nesting + 1)
            if value == nil then return nil, err end
            result[index] = value
        end
        return result, nil
    elseif schema.type == "object" then
        local object, properties = bounds.object(raw), bounds.object(schema.properties)
        if not object or not properties or schema.additionalProperties ~= false then return nil, label .. ": expected declared object" end
        local result: {[string]: unknown} = {}
        local count = 0
        for name, item in pairs(object) do
            count = count + 1
            if count > 64 or properties[name] == nil then return nil, label .. ": undeclared or excessive object fields" end
            local value, err = M.decode(properties[name], item, label .. "." .. name, nesting + 1)
            if value == nil then return nil, err end
            result[name] = value
        end
        if schema.required ~= nil then
            local required = bounds.ids(schema.required, true)
            if not required then return nil, label .. ": invalid required fields" end
            for _, name in ipairs(required) do if result[name] == nil then return nil, label .. ": missing " .. name end end
        end
        return result, nil
    end
    return nil, label .. ": value does not match declared " .. tostring(schema.type)
end
return M

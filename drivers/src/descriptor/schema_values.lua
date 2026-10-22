-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
type Value = string | number | boolean | {[string]: unknown} | {unknown}
function M.decode(raw_schema: unknown, raw: unknown, label: string, depth: integer?): (Value?, string?)
    local schema = bounds.object(raw_schema)
    local nesting = depth or 0
    if not schema or nesting > 8 then return nil, label .. ": invalid or overnested value schema" end
    local variants = bounds.ids(schema.type, true)
    if variants then
        for _, kind in ipairs(variants) do
            local variant: {[string]: unknown} = {}
            for key, item in pairs(schema) do variant[key] = item end
            variant.type = kind
            local shape = type(raw) == "table" and next(raw) == nil and canonical.encode(raw) or nil
            if not (kind == "object" and shape == "[]") and not (kind == "array" and shape == "{}") then
                local value = M.decode(variant, raw, label, nesting)
                if value ~= nil then return value, nil end
            end
        end
        return nil, label .. ": value is outside the declared types"
    end
    if next(schema) == nil then
        local kind = type(raw)
        if kind == "table" then
            local rows = bounds.array(raw, 64)
            if rows and (next(raw) ~= nil or canonical.encode(raw) == "[]") then
                return M.decode({type = "array", items = {}}, raw, label, nesting)
            end
            return M.decode({type = "object", additionalProperties = true}, raw, label, nesting)
        end
        return M.decode({type = kind == "number" and "number" or (kind == "boolean" and "boolean" or "string")}, raw, label, nesting)
    end
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
        if schema.pattern ~= nil then
            local patterns = type(schema.pattern) == "string" and {schema.pattern} or bounds.array(schema.pattern, 16)
            local matched = false
            for _, pattern in ipairs(patterns or {}) do
                if type(pattern) ~= "string" then return nil, label .. ": invalid text pattern" end
                local ok, result = pcall(string.match, value, pattern)
                if not ok then return nil, label .. ": invalid text pattern" end
                if result ~= nil then matched = true end
            end
            if not matched then return nil, label .. ": text does not match the declared pattern" end
        end
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
        if next(rows) == nil then return canonical.empty_like(raw), nil end
        for index, item in ipairs(rows) do
            local value, err = M.decode(schema.items, item, label .. "[" .. tostring(index) .. "]", nesting + 1)
            if value == nil then return nil, err end
            result[index] = value
        end
        return result, nil
    elseif schema.type == "object" then
        local object, properties = bounds.object(raw), bounds.object(schema.properties) or {}
        local additional = schema.additionalProperties == true and {} or bounds.object(schema.additionalProperties)
        if not object or (schema.additionalProperties ~= false and not additional) then return nil, label .. ": expected declared object" end
        local result: {[string]: unknown} = next(object) == nil and canonical.empty_like(object) or {}
        local count = 0
        local limit = math.floor(math.min(bounds.count(schema.maxProperties) or 64, 64))
        for name, item in pairs(object) do
            count = count + 1
            local value_schema = properties[name] or additional
            if count > limit or not value_schema or name == "" or #name > 128 or name:find("%c") then return nil, label .. ": undeclared or excessive object fields" end
            local value, err = M.decode(value_schema, item, label .. "." .. name, nesting + 1)
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

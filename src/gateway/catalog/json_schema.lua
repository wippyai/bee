-- MIT. A validator for the closed JSON Schema subset the session tools
-- publish: draft 2020-12 keywords over dereferenced schemas. An empty schema
-- admits any JSON value within the protocol size and depth bounds.
local json = require("json")
local text = require("text")
local bounds = require("bounds")
local M = {}
M.MAX_VALUE_BYTES = 65536
M.MAX_DEPTH = 16
type Object = {[string]: unknown}

-- A schema pattern is an ECMA-262 regular expression, compiled once per
-- pattern by the runtime's RE2 engine; a pattern it cannot compile makes the
-- schema invalid.
local patterns = {}
local function regex(pattern: string)
    local cached = patterns[pattern]
    if cached then return cached end
    local compiled = text.regexp.compile(pattern)
    if compiled then patterns[pattern] = compiled end
    return compiled
end

type Schema = {empty: boolean, type: string?, const: unknown, enum: {unknown}?,
    minLength: number?, maxLength: number?, pattern: string?, format: string?,
    minimum: number?, maximum: number?, exclusiveMinimum: number?, exclusiveMaximum: number?, minProperties: number?, maxProperties: number?, minItems: number?, maxItems: number?,
    uniqueItems: boolean?, items: Schema?, properties: {[string]: Schema}, required: {string},
    additionalProperties: boolean?, additionalSchema: Schema?, allOf: {Schema}, oneOf: {Schema}?, anyOf: {Schema}?,
    schema_not: Schema?, schema_if: Schema?, schema_then: Schema?, schema_else: Schema?}
local decode_schema: (unknown) -> Schema?
decode_schema = function(value: unknown): Schema?
    local raw = bounds.object(value)
    if not raw then return nil end
    local declared_type: string? = nil
    if raw.type ~= nil then
        local value = raw.type
        if type(value) ~= "string" then return nil end
        declared_type = value
    end
    local minLength: number? = nil
    if raw.minLength ~= nil then
        local value = raw.minLength
        if type(value) ~= "number" then return nil end
        minLength = value
    end
    local maxLength: number? = nil
    if raw.maxLength ~= nil then
        local value = raw.maxLength
        if type(value) ~= "number" then return nil end
        maxLength = value
    end
    local pattern: string? = nil
    if raw.pattern ~= nil then
        local value = raw.pattern
        if type(value) ~= "string" or not regex(value) then return nil end
        pattern = value
    end
    local format: string? = nil
    if raw.format ~= nil then
        local value = raw.format
        if type(value) ~= "string" then return nil end
        format = value
    end
    local minimum: number? = nil
    if raw.minimum ~= nil then
        local value = raw.minimum
        if type(value) ~= "number" then return nil end
        minimum = value
    end
    local maximum: number? = nil
    if raw.maximum ~= nil then
        local value = raw.maximum
        if type(value) ~= "number" then return nil end
        maximum = value
    end
    local minItems: number? = nil
    if raw.minItems ~= nil then
        local value = raw.minItems
        if type(value) ~= "number" then return nil end
        minItems = value
    end
    local maxItems: number? = nil
    if raw.maxItems ~= nil then
        local value = raw.maxItems
        if type(value) ~= "number" then return nil end
        maxItems = value
    end
    local uniqueItems: boolean? = nil
    if raw.uniqueItems ~= nil then
        local value = raw.uniqueItems
        if type(value) ~= "boolean" then return nil end
        uniqueItems = value
    end
    local exclusiveMinimum: number? = nil
    local exclusiveMaximum: number? = nil
    local minProperties: number? = nil
    local maxProperties: number? = nil
    for _, key in ipairs({"exclusiveMinimum", "exclusiveMaximum", "minProperties", "maxProperties"}) do
        local bound = raw[key]
        if bound ~= nil then
            if type(bound) ~= "number" or bound ~= bound or bound == math.huge or bound == -math.huge then return nil end
            if key == "exclusiveMinimum" then exclusiveMinimum = bound
            elseif key == "exclusiveMaximum" then exclusiveMaximum = bound
            elseif key == "minProperties" then minProperties = bound
            else maxProperties = bound end
        end
    end
    local additionalProperties: boolean? = nil
    local additionalSchema: Schema? = nil
    if raw.additionalProperties ~= nil then
        local value = raw.additionalProperties
        if type(value) == "boolean" then additionalProperties = value
        else
            additionalSchema = decode_schema(value)
            if not additionalSchema then return nil end
        end
    end
    local enum = raw.enum
    if enum ~= nil and type(enum) ~= "table" then return nil end
    local enum_values: {unknown}? = nil
    if type(enum) == "table" then
        local values: {unknown} = {}
        for index, item in ipairs(enum) do values[index] = item end
        enum_values = values
    end
    local properties: {[string]: Schema} = {}
    if raw.properties ~= nil then
        local entries = bounds.object(raw.properties)
        if not entries then return nil end
        for name, child in pairs(entries) do
            local decoded = decode_schema(child)
            if not decoded then return nil end
            properties[name] = decoded
        end
    end
    local required: {string} = {}
    if raw.required ~= nil then
        local source = raw.required
        if type(source) ~= "table" then return nil end
        for index, name in ipairs(source) do
            if type(name) ~= "string" then return nil end
            required[index] = name
        end
    end
    local schema_items: Schema? = nil
    if raw["items"] ~= nil then
        schema_items = decode_schema(raw["items"])
        if not schema_items then return nil end
    end
    local schema_not: Schema? = nil
    if raw["not"] ~= nil then
        schema_not = decode_schema(raw["not"])
        if not schema_not then return nil end
    end
    local schema_if: Schema? = nil
    if raw["if"] ~= nil then
        schema_if = decode_schema(raw["if"])
        if not schema_if then return nil end
    end
    local schema_then: Schema? = nil
    if raw["then"] ~= nil then
        schema_then = decode_schema(raw["then"])
        if not schema_then then return nil end
    end
    local schema_else: Schema? = nil
    if raw["else"] ~= nil then
        schema_else = decode_schema(raw["else"])
        if not schema_else then return nil end
    end
    local allOf: {Schema}? = nil
    if raw.allOf ~= nil then
        local source = raw.allOf
        if type(source) ~= "table" then return nil end
        local decoded: {Schema} = {}
        for index, child in ipairs(source) do
            local item = decode_schema(child)
            if not item then return nil end
            decoded[index] = item
        end
        allOf = decoded
    end
    local oneOf: {Schema}? = nil
    if raw.oneOf ~= nil then
        local source = raw.oneOf
        if type(source) ~= "table" then return nil end
        local decoded: {Schema} = {}
        for index, child in ipairs(source) do
            local item = decode_schema(child)
            if not item then return nil end
            decoded[index] = item
        end
        oneOf = decoded
    end
    local anyOf: {Schema}? = nil
    if raw.anyOf ~= nil then
        local source = raw.anyOf
        if type(source) ~= "table" then return nil end
        local decoded: {Schema} = {}
        for index, child in ipairs(source) do
            local item = decode_schema(child)
            if not item then return nil end
            decoded[index] = item
        end
        anyOf = decoded
    end
    return {
        type = declared_type,
        minLength = minLength,
        maxLength = maxLength,
        pattern = pattern,
        format = format,
        exclusiveMinimum = exclusiveMinimum, exclusiveMaximum = exclusiveMaximum,
        minProperties = minProperties, maxProperties = maxProperties, additionalSchema = additionalSchema,
        minimum = minimum,
        maximum = maximum,
        minItems = minItems,
        maxItems = maxItems,
        uniqueItems = uniqueItems,
        additionalProperties = additionalProperties,
        empty = next(raw) == nil,
        const = raw.const,
        enum = enum_values,
        properties = properties,
        required = required,
        allOf = allOf or {},
        oneOf = oneOf,
        anyOf = anyOf,
        ["items"] = schema_items,
        schema_not = schema_not,
        schema_if = schema_if,
        schema_then = schema_then,
        schema_else = schema_else}
end


local function kind_of(value: unknown): string
    local t = type(value)
    if t == "table" then
        local strings, numbers = 0, 0
        for key in pairs(value) do
            if type(key) == "string" then strings = strings + 1 elseif type(key) == "number" then numbers = numbers + 1 else return "invalid" end
        end
        if strings > 0 and numbers > 0 then return "invalid" end
        if numbers > 0 then
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            for index = 1, count do if (value)[index] == nil then return "invalid" end end
            return "array"
        end
        return "object"
    end
    if t == "number" then
        local number = value
        if number ~= number or number == math.huge or number == -math.huge then return "invalid" end
        if number == math.floor(number) then return "integer" end
        return "number"
    end
    return t
end

local function depth_of(value: unknown, depth: integer): integer
    if type(value) ~= "table" then return depth end
    local deepest = depth + 1
    for _, child in pairs(value) do
        local found = depth_of(child, depth + 1)
        if found > deepest then deepest = found end
    end
    return deepest
end

local function count_of(value: table): integer
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function date_time(value: string): boolean
    local year, month, day, hour, minute, second, rest = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
    if not year or not month or not day or not hour or not minute or not second or not rest then return false end
    local m, d, h, n, s = assert(tonumber(month)), assert(tonumber(day)), assert(tonumber(hour)),
        assert(tonumber(minute)), assert(tonumber(second))
    if m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or n > 59 or s > 60 then return false end
    rest = rest:gsub("^%.%d+", "")
    if rest == "Z" or rest == "z" then return true end
    local zh, zm = rest:match("^[+-](%d%d):(%d%d)$")
    if not zh or not zm then return false end
    return assert(tonumber(zh)) <= 23 and assert(tonumber(zm)) <= 59
end

local function same(left: unknown, right: unknown): boolean
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    if type(right) ~= "table" then return false end
    for key, value in pairs(left) do if not same(value, (right)[key]) then return false end end
    return count_of(left) == count_of(right)
end

local check: (Schema, unknown, string) -> string?

local function matches(schema: Schema, value: unknown): boolean
    return check(schema, value, "") == nil
end

check = function(schema: Schema, value: unknown, path: string): string?
    if schema.empty then
        if kind_of(value) == "invalid" then return path .. " is not a JSON value" end
        local encoded = json.encode(value)
        if not encoded or #encoded > M.MAX_VALUE_BYTES then return path .. " exceeds the JSON value bound" end
        if depth_of(value, 0) > M.MAX_DEPTH then return path .. " exceeds the JSON depth bound" end
        return nil
    end
    local kind = kind_of(value)
    local declared = schema.type
    if declared == "array" and kind == "object" and type(value) == "table" and next(value) == nil then kind = "array" end
    if declared ~= nil then
        local ok = kind == declared or (declared == "number" and kind == "integer")
        if not ok then return path .. " must be " .. tostring(declared) end
    end
    if schema.const ~= nil and not same(schema.const, value) then return path .. " has the wrong constant" end
    if schema.enum ~= nil then
        local found = false
        for _, item in ipairs(schema.enum) do if same(item, value) then found = true end end
        if not found then return path .. " is not an admitted value" end
    end
    if kind == "string" and type(value) == "string" then
        local str = value
        if schema.minLength ~= nil and #str < (schema.minLength) then return path .. " is too short" end
        if schema.maxLength ~= nil and #str > (schema.maxLength) then return path .. " is too long" end
        if schema.pattern ~= nil then
            local compiled = regex(schema.pattern)
            if not compiled or not compiled:match_string(str) then return path .. " has the wrong form" end
        end
        if schema.format == "date-time" and not date_time(str) then return path .. " must be an RFC 3339 date-time" end
    elseif (kind == "integer" or kind == "number") and type(value) == "number" then
        local number = value
        if schema.exclusiveMinimum ~= nil and number <= schema.exclusiveMinimum then return path .. " is not above its exclusive minimum" end
        if schema.exclusiveMaximum ~= nil and number >= schema.exclusiveMaximum then return path .. " is not below its exclusive maximum" end
        if schema.minimum ~= nil and number < (schema.minimum) then return path .. " is below its minimum" end
        if schema.maximum ~= nil and number > (schema.maximum) then return path .. " is above its maximum" end
    elseif kind == "array" and type(value) == "table" then
        local items = value
        local size = count_of(items)
        if schema.minItems ~= nil and size < (schema.minItems) then return path .. " has too few items" end
        if schema.maxItems ~= nil and size > (schema.maxItems) then return path .. " has too many items" end
        if schema.uniqueItems == true then
            for left = 1, size do
                for right = left + 1, size do
                    if same(items[left], items[right]) then return path .. " has duplicate items" end
                end
            end
        end
        if schema.items ~= nil then
            for index = 1, size do
                local failure = check(schema.items, items[index], path .. "[" .. tostring(index) .. "]")
                if failure then return failure end
            end
        end
    elseif kind == "object" and type(value) == "table" then
        local object = value
        local size = count_of(object)
        if schema.minProperties ~= nil and size < schema.minProperties then return path .. " has too few properties" end
        if schema.maxProperties ~= nil and size > schema.maxProperties then return path .. " has too many properties" end
        local properties = (schema.properties or {})
        for _, name in ipairs((schema.required or {})) do
            if object[name] == nil then return path .. "." .. name .. " is required" end
        end
        for name, child in pairs(object) do
            local child_schema = properties[name]
            if child_schema ~= nil then
                local failure = check(child_schema, child, path .. "." .. tostring(name))
                if failure then return failure end
            elseif schema.additionalSchema ~= nil then
                local failure = check(schema.additionalSchema, child, path .. "." .. tostring(name))
                if failure then return failure end
            elseif schema.additionalProperties == false then
                return "unknown field " .. tostring(name)
            end
        end
    end
    for _, part in ipairs((schema.allOf or {})) do
        local failure = check(part, value, path)
        if failure then return failure end
    end
    if schema.oneOf ~= nil then
        local matched = 0
        local refusals: {string} = {}
        for index, branch in ipairs(schema.oneOf) do
            local failure = check(branch, value, path)
            if failure then refusals[#refusals + 1] = "form " .. tostring(index) .. ": " .. failure:sub(1, 512) else matched = matched + 1 end
        end
        if matched > 1 then return path .. " must match exactly one admitted form" end
        if matched == 0 then return path .. " must match exactly one admitted form (" .. table.concat(refusals, "; ") .. ")" end
    end
    if schema.anyOf ~= nil then
        local matched = false
        for _, branch in ipairs(schema.anyOf) do if matches(branch, value) then matched = true end end
        if not matched then return path .. " must match an admitted form" end
    end
    if schema.schema_not ~= nil and matches(schema.schema_not, value) then return path .. " has a forbidden form" end
    if schema.schema_if ~= nil then
        if matches(schema.schema_if, value) then
            if schema.schema_then ~= nil then
                local failure = check(schema.schema_then, value, path)
                if failure then return failure end
            end
        elseif schema.schema_else ~= nil then
            local failure = check(schema.schema_else, value, path)
            if failure then return failure end
        end
    end
    return nil
end

-- validate: nil when the value conforms, else the first violation.
function M.validate(schema: Object, value: unknown): string?
    local decoded = decode_schema(schema)
    if not decoded then return "invalid JSON schema" end
    return check(decoded, value, "arguments")
end

return M

-- MIT. A validator for the closed JSON Schema subset the session tools
-- publish: draft 2020-12 keywords over dereferenced schemas. An empty schema
-- admits any JSON value within the protocol size and depth bounds.
local json = require("json")
local M = {}
M.MAX_VALUE_BYTES = 65536
M.MAX_DEPTH = 16
type Object = {[string]: unknown}

local function kind_of(value: unknown): string
    local t = type(value)
    if t == "table" then
        local strings, numbers = 0, 0
        for key in pairs(value :: Object) do
            if type(key) == "string" then strings = strings + 1 elseif type(key) == "number" then numbers = numbers + 1 else return "invalid" end
        end
        if strings > 0 and numbers > 0 then return "invalid" end
        if numbers > 0 then
            local count = 0
            for _ in pairs(value :: Object) do count = count + 1 end
            for index = 1, count do if (value :: Object)[index] == nil then return "invalid" end end
            return "array"
        end
        return "object"
    end
    if t == "number" then
        local number = value :: number
        if number ~= number or number == math.huge or number == -math.huge then return "invalid" end
        if number == math.floor(number) then return "integer" end
        return "number"
    end
    return t
end

local function depth_of(value: unknown, depth: integer): integer
    if type(value) ~= "table" then return depth end
    local deepest = depth + 1
    for _, child in pairs(value :: Object) do
        local found = depth_of(child, depth + 1)
        if found > deepest then deepest = found end
    end
    return deepest
end

local function count_of(value: unknown): integer
    local count = 0
    for _ in pairs(value :: Object) do count = count + 1 end
    return count
end

local function date_time(value: string): boolean
    local year, month, day, hour, minute, second, rest = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return false end
    local m, d, h, n, s = tonumber(month) :: number, tonumber(day) :: number, tonumber(hour) :: number,
        tonumber(minute) :: number, tonumber(second) :: number
    if m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or n > 59 or s > 60 then return false end
    rest = rest:gsub("^%.%d+", "")
    if rest == "Z" or rest == "z" then return true end
    local zh, zm = rest:match("^[+-](%d%d):(%d%d)$")
    return zh ~= nil and (tonumber(zh) :: number) <= 23 and (tonumber(zm) :: number) <= 59
end

local function same(left: unknown, right: unknown): boolean
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left :: Object) do if not same(value, (right :: Object)[key]) then return false end end
    return count_of(left) == count_of(right)
end

local check: (Object, unknown, string) -> string?

local function matches(schema: unknown, value: unknown): boolean
    return check(schema :: Object, value, "") == nil
end

check = function(schema: Object, value: unknown, path: string): string?
    if next(schema) == nil then
        if kind_of(value) == "invalid" then return path .. " is not a JSON value" end
        local encoded = json.encode(value)
        if not encoded or #encoded > M.MAX_VALUE_BYTES then return path .. " exceeds the JSON value bound" end
        if depth_of(value, 0) > M.MAX_DEPTH then return path .. " exceeds the JSON depth bound" end
        return nil
    end
    local kind = kind_of(value)
    local declared = schema.type
    if declared == "array" and kind == "object" and next(value :: Object) == nil then kind = "array" end
    if declared ~= nil then
        local ok = kind == declared or (declared == "number" and kind == "integer")
        if not ok then return path .. " must be " .. tostring(declared) end
    end
    if schema.const ~= nil and not same(schema.const, value) then return path .. " has the wrong constant" end
    if schema.enum ~= nil then
        local found = false
        for _, item in ipairs(schema.enum :: {unknown}) do if same(item, value) then found = true end end
        if not found then return path .. " is not an admitted value" end
    end
    if kind == "string" then
        local text = value :: string
        if schema.minLength ~= nil and #text < (schema.minLength :: number) then return path .. " is too short" end
        if schema.maxLength ~= nil and #text > (schema.maxLength :: number) then return path .. " is too long" end
        if schema.pattern ~= nil and not text:find(schema.pattern :: string) then return path .. " has the wrong form" end
        if schema.format == "date-time" and not date_time(text) then return path .. " must be an RFC 3339 date-time" end
    elseif kind == "integer" or kind == "number" then
        local number = value :: number
        if schema.minimum ~= nil and number < (schema.minimum :: number) then return path .. " is below its minimum" end
        if schema.maximum ~= nil and number > (schema.maximum :: number) then return path .. " is above its maximum" end
    elseif kind == "array" then
        local items = value :: {unknown}
        local size = count_of(items)
        if schema.minItems ~= nil and size < (schema.minItems :: number) then return path .. " has too few items" end
        if schema.maxItems ~= nil and size > (schema.maxItems :: number) then return path .. " has too many items" end
        if schema.uniqueItems == true then
            for left = 1, size do
                for right = left + 1, size do
                    if same(items[left], items[right]) then return path .. " has duplicate items" end
                end
            end
        end
        if schema.items ~= nil then
            for index = 1, size do
                local failure = check(schema.items :: Object, items[index], path .. "[" .. tostring(index) .. "]")
                if failure then return failure end
            end
        end
    elseif kind == "object" then
        local object = value :: Object
        local properties = (schema.properties or {}) :: Object
        for _, name in ipairs((schema.required or {}) :: {string}) do
            if object[name] == nil then return path .. "." .. name .. " is required" end
        end
        for name, child in pairs(object) do
            local child_schema = properties[name]
            if child_schema ~= nil then
                local failure = check(child_schema :: Object, child, path .. "." .. tostring(name))
                if failure then return failure end
            elseif schema.additionalProperties == false then
                return "unknown field " .. tostring(name)
            end
        end
    end
    for _, part in ipairs((schema.allOf or {}) :: {unknown}) do
        local failure = check(part :: Object, value, path)
        if failure then return failure end
    end
    if schema.oneOf ~= nil then
        local matched = 0
        for _, branch in ipairs(schema.oneOf :: {unknown}) do if matches(branch, value) then matched = matched + 1 end end
        if matched ~= 1 then return path .. " must match exactly one admitted form" end
    end
    if schema.anyOf ~= nil then
        local matched = false
        for _, branch in ipairs(schema.anyOf :: {unknown}) do if matches(branch, value) then matched = true end end
        if not matched then return path .. " must match an admitted form" end
    end
    if schema["not"] ~= nil and matches(schema["not"], value) then return path .. " has a forbidden form" end
    if schema["if"] ~= nil then
        if matches(schema["if"], value) then
            if schema["then"] ~= nil then
                local failure = check(schema["then"] :: Object, value, path)
                if failure then return failure end
            end
        elseif schema["else"] ~= nil then
            local failure = check(schema["else"] :: Object, value, path)
            if failure then return failure end
        end
    end
    return nil
end

-- validate: nil when the value conforms, else the first violation.
function M.validate(schema: Object, value: unknown): string?
    return check(schema, value, "arguments")
end

return M

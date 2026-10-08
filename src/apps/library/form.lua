-- MIT. Typed package configuration fields.
local bounds = require("bounds")
local json = require("json")
local json_schema = require("json_schema")
local requirements = require("requirements")
local M = {}
type Object = {[string]: unknown}
type Step = string | integer
type Declaration = {id: string, schema: Object?, default: unknown, has_default: boolean, capability: string?, description: string?}
type Field = {id: string, root: string, path: {Step}, schema: Object, kind: string,
    value: unknown, default: unknown, required: boolean, description: string, readonly: boolean, choices: {unknown}, origin: string}

function M.label(value: unknown): string
    if value == nil then return "Not set" end
    if type(value) == "string" then return value == "" and "(empty text)" or value end
    if type(value) == "table" then
        local parts: {string} = {}
        for key, item in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. M.label(item) end
        table.sort(parts)
        return table.concat(parts, ", ")
    end
    return tostring(value)
end

function M.get(value: unknown, path: {Step}): unknown
    local current = value
    for _, part in ipairs(path) do
        if type(current) ~= "table" then return nil end
        current = current[part]
    end
    return current
end

local function copy(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: {[unknown]: unknown} = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

function M.assign(root: unknown, path: {Step}, value: unknown): unknown
    if #path == 0 then return value end
    local copied = copy(root)
    local result = type(copied) == "table" and copied or {}
    local current = result
    for index = 1, #path - 1 do
        local key = path[index]
        local child = current[key]
        if type(child) ~= "table" then child = {}; current[key] = child end
        current = child
    end
    current[path[#path]] = value
    return result
end

local function kind(schema: Object, value: unknown): string
    if type(schema.type) == "string" then return schema.type end
    if bounds.object(schema.properties) then return "object" end
    if schema.items ~= nil then return "array" end
    if value ~= nil then return type(value) == "table" and "object" or type(value) end
    return "string"
end

function M.fields(declarations: {Declaration}, selected: {[string]: unknown}): ({Field}, string?)
    local fields: {Field} = {}
    local problem: string? = nil
    local function append(declaration: Declaration, schema: Object, path: {Step}, required: boolean, depth: integer)
        if depth > 16 or #fields >= 512 then problem = declaration.id .. ": configuration schema exceeds the form limit"; return end
        local chosen = selected[declaration.id]
        local fallback_root = requirements.defaults(declaration.schema or {}, declaration.default)
        local root = chosen ~= nil and chosen or fallback_root
        if chosen == false then root = false end
        local value, fallback = M.get(root, path), M.get(fallback_root, path)
        local name = declaration.id
        for _, part in ipairs(path) do name = name .. (type(part) == "number" and "[" .. tostring(part) .. "]" or "." .. tostring(part)) end
        local field_kind = kind(schema, value)
        local choices = bounds.array(schema.enum, 128) or {}
        fields[#fields + 1] = {id = name, root = declaration.id, path = path, schema = schema, kind = field_kind,
            value = value, default = fallback, required = required, readonly = declaration.capability ~= nil,
            choices = choices, description = bounds.text(schema.description, 4096) or declaration.description or "",
            origin = declaration.capability and "Provided by host" or (chosen ~= nil and "Selected" or (value ~= nil and "Default" or "Required"))}
        if declaration.capability or #choices > 0 then return end
        local properties = bounds.object(schema.properties)
        if field_kind == "object" and properties then
            local names: {string}, needed: {[string]: boolean} = {}, {}
            for _, name in ipairs(bounds.ids(schema.required, true) or {}) do needed[name] = true end
            for name in pairs(properties) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local child = bounds.object(properties[name])
                if child then
                    local next_path: {Step} = {}
                    for _, part in ipairs(path) do next_path[#next_path + 1] = part end
                    next_path[#next_path + 1] = name
                    append(declaration, child, next_path, needed[name] == true, depth + 1)
                end
            end
        elseif field_kind == "array" then
            local items = bounds.object(schema.items)
            if items and (kind(items, nil) == "object" or kind(items, nil) == "array") then
                for index in ipairs(bounds.array(value, 128) or {}) do
                    local next_path: {Step} = {}
                    for _, part in ipairs(path) do next_path[#next_path + 1] = part end
                    next_path[#next_path + 1] = math.floor(index)
                    append(declaration, items, next_path, true, depth + 1)
                end
            end
        end
    end
    for _, declaration in ipairs(declarations) do
        append(declaration, declaration.schema or {}, {}, not declaration.has_default and not declaration.capability, 0)
    end
    return fields, problem
end

function M.buffer(field: Field): string
    local value = field.value
    if value == nil then return "" end
    if field.kind == "array" then
        local values: {string} = {}
        for _, item in ipairs(bounds.array(value, 128) or {}) do values[#values + 1] = tostring(item) end
        return table.concat(values, ", ")
    end
    if type(value) == "table" then return json.encode(value) or "" end
    return tostring(value)
end

local function scalar(field_kind: string, input: string): (unknown, string?)
    if field_kind == "string" then return input, nil end
    if field_kind == "integer" or field_kind == "number" then
        local value = tonumber(input)
        if not value or value ~= value or value == math.huge or value == -math.huge
            or field_kind == "integer" and value ~= math.floor(value) then return nil, "Enter a " .. field_kind end
        return value, nil
    end
    if field_kind == "boolean" then
        if input == "true" then return true, nil end
        if input == "false" then return false, nil end
        return nil, "Choose true or false"
    end
    return nil, "Configure the fields below; J opens Advanced JSON"
end

function M.parse(field: Field, input: string): (unknown, string?)
    local value: unknown, problem: string?
    if field.kind == "array" then
        local items = bounds.object(field.schema.items) or {type = "string"}
        local values: {unknown} = {}
        if input ~= "" then
            for token in (input .. ","):gmatch("(.-),") do
                local item, invalid = scalar(kind(items, nil), token:match("^%s*(.-)%s*$") or token)
                if invalid then return nil, field.id .. ": " .. invalid end
                values[#values + 1] = item
            end
        end
        value = values
    else value, problem = scalar(field.kind, input) end
    if problem then return nil, field.id .. ": " .. problem end
    local invalid = json_schema.validate(field.schema, value)
    return value, invalid and field.id .. ": " .. invalid or nil
end

function M.validate(declaration: Declaration, value: unknown): string?
    if declaration.capability then return nil end
    if value == nil then return declaration.id .. " is required" end
    local problem = json_schema.validate(declaration.schema or {}, requirements.defaults(declaration.schema or {}, value))
    return problem and declaration.id .. ": " .. problem or nil
end

return M

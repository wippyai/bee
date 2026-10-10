local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Key = string | integer
type Row = {name: string, path: {Key}, label: string, kind: string, schema: Object, value: unknown, choices: {unknown}?}
local function child(path: {Key}, key: Key): {Key}
    local result: {Key} = {}
    for _, item in ipairs(path) do result[#result + 1] = item end
    result[#result + 1] = key
    return result
end
function M.rows(name: string, schema: Object, value: unknown): {Row}
    local rows: {Row} = {}
    local function walk(spec: Object, selected: unknown, path: {Key}, label: string, depth: integer)
        if depth > 6 or #rows >= 128 then return end
        local choices = bounds.array(spec.enum, 64)
        if choices or spec.type == "boolean" then
            rows[#rows + 1] = {name = name, path = path, label = label, kind = "choice", schema = spec, value = selected, choices = choices or {false, true}}
        elseif spec.type == "object" or spec.type == "array" then
            if selected == nil then
                rows[#rows + 1] = {name = name, path = path, label = label .. ": Set", kind = "create", schema = spec}
                return
            end
            local object = type(selected) == "table" and selected or {}
            if spec.type == "array" then
                local item_schema = bounds.object(spec.items) or {}
                for index, item in ipairs(object) do
                    walk(item_schema, item, child(path, index), label .. " [" .. tostring(index) .. "]", depth + 1)
                    rows[#rows + 1] = {name = name, path = child(path, index), label = label .. " [" .. tostring(index) .. "]: Remove", kind = "remove", schema = item_schema}
                end
                rows[#rows + 1] = {name = name, path = path, label = label .. ": Add item", kind = "append", schema = item_schema}
            else
                local properties = bounds.object(spec.properties) or {}
                local keys: {string} = {}
                for key in pairs(properties) do keys[#keys + 1] = key end
                table.sort(keys)
                for _, key in ipairs(keys) do walk(bounds.object(properties[key]) or {}, object[key], child(path, key), label .. " / " .. key, depth + 1) end
                local additional = bounds.object(spec.additionalProperties)
                if additional then
                    local names: {string} = {}
                    for key in pairs(object) do if type(key) == "string" and properties[key] == nil then names[#names + 1] = key end end
                    table.sort(names)
                    for _, key in ipairs(names) do
                        walk(additional, object[key], child(path, key), label .. " / " .. key, depth + 1)
                        rows[#rows + 1] = {name = name, path = child(path, key), label = label .. " / " .. key .. ": Remove", kind = "remove", schema = additional}
                    end
                    rows[#rows + 1] = {name = name, path = path, label = label .. ": New entry name", kind = "key", schema = additional}
                end
            end
        else rows[#rows + 1] = {name = name, path = path, label = label, kind = "text", schema = spec, value = selected} end
    end
    walk(schema, value, {}, name, 0)
    return rows
end
local function initial(schema: Object): unknown
    if schema.type == "object" or schema.type == "array" then return {} end
    if schema.type == "boolean" then return false end
    if schema.type == "number" or schema.type == "integer" then return schema.minimum or 0 end
    local choices = bounds.array(schema.enum, 64)
    return choices and choices[1] or ""
end
local function remove_item(value: unknown, index: integer)
    if type(value) ~= "table" then return end
    for position = index, #value do value[position] = value[position + 1] end
end
function M.change(values: Object, row: Row, text: string?, direction: integer?): string?
    local parent: unknown = values
    local key: Key = row.name
    for _, segment in ipairs(row.path) do
        if type(parent) ~= "table" then return "Option parent is unavailable" end
        local nested = parent[key]
        if type(nested) ~= "table" then return "Option parent is unavailable" end
        parent = nested
        key = segment
    end
    if type(parent) ~= "table" then return "Option parent is unavailable" end
    if row.kind == "create" then parent[key] = {}
    elseif row.kind == "remove" then
        if type(key) == "number" then
            remove_item(parent, key)
        else parent[key] = nil end
    elseif row.kind == "append" or row.kind == "key" then
        local selected = parent[key]
        if type(selected) ~= "table" then return "Option collection is unavailable" end
        if row.kind == "append" then selected[#selected + 1] = initial(row.schema)
        else
            if not text or text == "" or #text > 128 or text:find("%c") or selected[text] ~= nil then return "Choose a unique bounded entry name" end
            selected[text] = initial(row.schema)
        end
    elseif row.kind == "choice" then
        local choices = row.choices or {}
        local index = 0
        for position, candidate in ipairs(choices) do if candidate == parent[key] then index = position end end
        index = (index + (direction or 1)) % (#choices + 1)
        parent[key] = index > 0 and choices[index] or nil
        if index > 0 then parent[key] = choices[index] end
    else
        if not text or text == "" then parent[key] = nil
        elseif row.schema.type == "number" or row.schema.type == "integer" then
            local value = tonumber(text)
            if not value or value ~= value or value == math.huge or value == -math.huge or (row.schema.type == "integer" and value ~= math.floor(value)) then return "Enter a finite " .. tostring(row.schema.type) end
            parent[key] = value
        else parent[key] = text end
    end
    return nil
end
return M

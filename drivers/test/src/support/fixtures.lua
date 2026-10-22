-- MIT. Typed views of fixture lists a suite asserts over: each helper fails
-- the case when the value is not the list it expects.
local bounds = require("bounds")
local registry = require("registry")
local M = {}
function M.items(raw: unknown): {unknown}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    return assert(bounds.array(raw, #raw))
end
function M.objects(raw: unknown, maximum: integer?): {{[string]: unknown}}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    local rows = assert(bounds.array(raw, maximum or #raw))
    local objects: {{[string]: unknown}} = {}
    for index, row in ipairs(rows) do objects[index] = assert(bounds.object(row)) end
    return objects
end
function M.strings(raw: unknown, maximum: integer?): {string}
    if type(raw) ~= "table" then error("fixture list must be a table") end
    local rows = assert(bounds.array(raw, maximum or #raw))
    local strings: {string} = {}
    for index, row in ipairs(rows) do
        if type(row) ~= "string" then error("fixture list item must be text") end
        strings[index] = row
    end
    return strings
end
function M.registry_input(value: {[string]: unknown}): RegistryInput
    local id, kind, meta, dependency_root = value.id, value.kind, value.meta, value.dependency_root
    assert(type(id) == "string" and type(kind) == "string", "fixture registry entry identity")
    local metadata: {[string]: unknown} = {}
    if meta ~= nil then
        assert(type(meta) == "table", "fixture registry metadata")
        for key, item in pairs(meta) do metadata[key] = item end
    end
    assert(dependency_root == nil or type(dependency_root) == "boolean", "fixture registry dependency root")
    return {id = id, kind = kind, meta = metadata, data = value.data, dependency_root = dependency_root == true}
end

function M.contains(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
function M.count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
return M

-- MIT. Typed views of fixture lists a suite asserts over: each helper fails
-- the case when the value is not the list it expects.
local bounds = require("bounds")
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
return M

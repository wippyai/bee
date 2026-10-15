-- MIT. Value snapshots fence activation against changes to measured registry inputs.
local M = {}
type Object = {[string]: unknown}
local function copy(value: unknown): unknown
    if type(value) ~= "table" then return value end
    local result: Object = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function equal(left: unknown, right: unknown): boolean
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

M.copy = copy
M.equal = equal
return M

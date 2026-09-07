-- Read only protected bindings; app metadata cannot select its own permissions.
local registry = require("registry")
local contract = require("contract")
local M = {}
function M.bindings(): {contract.Binding}
    local entry, err = registry.get("bee:application_admission")
    if err then error(tostring(err)) end
    local data: unknown = entry.data
    if type(data) ~= "table" or type(data.bindings) ~= "table" then error("Invalid application admission") end
    local result: {contract.Binding} = {}
    local count = 0
    for key in pairs(data.bindings) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 64 then error("Invalid admission array") end
        count = count + 1
    end
    local seen: {[string]: boolean} = {}
    for i = 1, count do
        local binding = contract.binding(data.bindings[i])
        if not binding or seen[binding.definition_id] then error("Invalid or duplicate admission binding") end
        seen[binding.definition_id] = true; result[#result + 1] = binding
    end
    return result
end
function M.descriptor(id: string): contract.Descriptor?
    local entry, err = registry.get(id)
    if err or not entry or entry.kind ~= "process.lua" or entry.meta.type ~= "bee.application" then return nil end
    return contract.descriptor(id, entry.meta.application)
end
function M.items(bindings: {contract.Binding}): {contract.Descriptor}
    local result: {contract.Descriptor} = {}
    for _, binding in ipairs(bindings) do
        local item = M.descriptor(binding.definition_id)
        if item then result[#result + 1] = item end
    end
    table.sort(result, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.title ~= b.title then return a.title < b.title end
        return a.definition_id < b.definition_id
    end)
    return result
end
return M

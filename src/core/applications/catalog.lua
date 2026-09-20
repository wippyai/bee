-- Read only protected bindings; app metadata cannot select its own permissions.
local registry = require("registry")
local contract = require("contract")
local M = {}
type Selection = {revision: string, bindings: {contract.Binding}, items: {contract.Descriptor}}
function M.bindings(pinned: registry.Snapshot?): {contract.Binding}
    local entry, err
    if pinned then entry, err = pinned:get("bee:application_admission")
    else entry, err = registry.get("bee:application_admission") end
    if err or not entry or entry.kind ~= "registry.entry" then error("Invalid application admission: " .. tostring(err)) end
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
function M.descriptor(id: string, pinned: registry.Snapshot?): contract.Descriptor?
    local entry, err
    if pinned then entry, err = pinned:get(id) else entry, err = registry.get(id) end
    if err or not entry or entry.kind ~= "process.lua" or entry.meta.type ~= "bee.application" then return nil end
    return contract.descriptor(id, entry.meta.application)
end
function M.items(bindings: {contract.Binding}, pinned: registry.Snapshot?): {contract.Descriptor}
    local result: {contract.Descriptor} = {}
    for _, binding in ipairs(bindings) do
        local item = M.descriptor(binding.definition_id, pinned)
        if item then result[#result + 1] = item end
    end
    table.sort(result, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        if a.title ~= b.title then return a.title < b.title end
        return a.definition_id < b.definition_id
    end)
    return result
end
-- Overlays change the effective catalog without advancing registry history.
-- Compare the bounded admission/presentation values captured in one snapshot;
-- source code and unrelated registry entries are not serialized here.
function M.read(): Selection
    local pinned = assert(registry.snapshot())
    local revision = pinned:version():string()
    local bindings = M.bindings(pinned)
    local items = M.items(bindings, pinned)
    return {revision = revision, bindings = bindings, items = items}
end
-- These are bounded, decoded records, not arbitrary registry data. Compare
-- values directly: JSON object field order is not a catalog revision.
function M.same(a: Selection, b: Selection): boolean
    if a.revision ~= b.revision or #a.bindings ~= #b.bindings or #a.items ~= #b.items then return false end
    for i, left in ipairs(a.bindings) do
        local right = b.bindings[i]
        if left.definition_id ~= right.definition_id or left.appearance_write ~= right.appearance_write
            or left.application_stop ~= right.application_stop or left.catalog_read ~= right.catalog_read
            or left.scope_management ~= right.scope_management or left.close_grace_ms ~= right.close_grace_ms
            or left.thread_access ~= right.thread_access
            or #left.policies ~= #right.policies then return false end
        for j, policy in ipairs(left.policies) do
            if policy ~= right.policies[j] then return false end
        end
    end
    for i, left in ipairs(a.items) do
        local right = b.items[i]
        if left.definition_id ~= right.definition_id or left.definition_revision ~= right.definition_revision
            or left.title ~= right.title or left.icon ~= right.icon or left.group ~= right.group
            or left.role ~= right.role or left.singleton ~= right.singleton
            or left.resume_schema ~= right.resume_schema or left.restart_policy ~= right.restart_policy then return false end
    end
    return true
end
-- Only an exact compatible automatic definition update may replace a running
-- application through recovery. Incompatible checkpoints stay live until the
-- person closes them; the catalog itself grants no destructive authority.
function M.replaces(running: contract.Descriptor, replacement: contract.Descriptor?): boolean
    return replacement ~= nil and running.restart_policy == "automatic"
        and replacement.restart_policy == "automatic"
        and replacement.resume_schema == running.resume_schema
        and replacement.definition_revision ~= running.definition_revision
end
return M

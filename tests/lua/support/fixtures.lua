-- MIT. Typed views of fixture lists a suite asserts over: each helper fails
-- the case when the value is not the list it expects.
local bounds = require("bounds")
local registry = require("registry")
local sql = require("sql")
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
function M.registry_cleanup(governed: boolean?): () -> ()
    local before: {[string]: boolean} = {}
    for _, entry in ipairs(assert(registry.snapshot():state()).entries) do before[entry.id] = true end
    return function()
        local owners: {[string]: boolean} = {}
        local state = assert(registry.snapshot():state())
        for _, entry in ipairs(state.entries) do
            local data = bounds.object(entry.data)
            local owner = data and data.overlay_owner
            if type(owner) == "string" then owners[owner] = true end
        end
        if governed then
            local db = assert(sql.get("bee:db"))
            for _, row in ipairs(assert(db:query("SELECT DISTINCT overlay_owner FROM bee_governance_activation_intents"))) do
                owners[assert(bounds.id(row.overlay_owner))] = true
            end
            db:release()
        end
        for owner in pairs(owners) do
            local overlay = assert(registry.overlay(owner))
            local changes = overlay:changes()
            local changed = false
            for _, entry in ipairs(assert(overlay:entries())) do
                if not before[entry.id] then changes:delete(entry.id); changed = true end
            end
            if changed then assert(changes:apply()) end
        end
        local durable: {string} = {}
        for _, entry in ipairs(assert(registry.snapshot():state()).entries) do
            if not before[entry.id] then durable[#durable + 1] = entry.id end
        end
        if #durable > 0 then
            local changes = registry.snapshot():changes()
            for _, id in ipairs(durable) do changes:delete(id) end
            assert(changes:apply())
        end
    end
end
return M

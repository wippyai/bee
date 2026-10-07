-- MIT. Test association by registry ownership and explicit application metadata.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Found = {id: string, name: string, group: string, meta: {[string]: any}}
function M.select(raw: unknown, application_id: string, owned: {[string]: boolean}): ({Found}?, string?)
    local rows, problem = bounds.dense_list(raw, 16384, "application test registry entries")
    if not rows then return nil, problem end
    local entries: {Object} = {}
    local package: string? = nil
    for _, raw_entry in ipairs(rows) do
        local entry = bounds.object(raw_entry)
        if not entry or not bounds.id(entry.id) or not bounds.id(entry.kind) then
            return nil, "application test registry entry is invalid"
        end
        entries[#entries + 1] = entry
        if entry.id == application_id then
            local provenance = bounds.object(entry.registry)
            package = provenance and bounds.line(provenance.owner, 160) or nil
        end
    end
    local applications = 0
    for _, entry in ipairs(entries) do
        local provenance = bounds.object(entry.registry)
        local meta = bounds.object(entry.meta)
        local same_source = owned[application_id] and owned[entry.id]
            or (not owned[application_id] and package and provenance and provenance.owner == package)
        if same_source and entry.kind == "process.lua" and meta and meta.type == "bee.app" then
            applications = applications + 1
        end
    end
    local result: {Found} = {}
    for _, entry in ipairs(entries) do
        local meta = bounds.object(entry.meta)
        local provenance = bounds.object(entry.registry)
        local same_source = owned[application_id] and owned[entry.id]
            or (not owned[application_id] and package and provenance and provenance.owner == package)
        if same_source and entry.kind == "function.lua" and meta and meta.type == "test"
            and (meta.application == application_id or (meta.application == nil and applications == 1)) then
            local id = assert(bounds.id(entry.id))
            result[#result + 1] = {id = id, name = id, group = application_id, meta = meta}
        end
    end
    return result, nil
end
return M

-- MIT. The sync package owns a requirement hole rather than selecting a
-- workspace database. An owner may also pass an explicit linked resource to
-- `sync.open` when it owns the higher-level requirement.
local registry = require("registry")
local M = {}
M.DATABASE_REF = "bee.sync:database_ref"
M.EXPORTS_REF = "bee.sync.registry:exports_ref"

local function reference(id: string, label: string): (string?, string?)
    local entry = registry.get(id)
    if not entry or type(entry.data) ~= "table" then return nil, label .. " reference unavailable" end
    local target: unknown = (entry.data :: {[string]: unknown}).resource_ref
    if type(target) ~= "string" or target == "" then return nil, label .. " reference is not linked" end
    return target, nil
end

function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "sync database")
end

function M.exports(): (string?, string?)
    return reference(M.EXPORTS_REF, "sync exports")
end
return M

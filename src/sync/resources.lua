-- MIT. The sync package owns a requirement hole rather than selecting a
-- workspace database. An owner may also pass an explicit linked resource to
-- `sync.open` when it owns the higher-level requirement.
local registry = require("registry")
local M = {}
function M.database(): (string?, string?)
    local entry = registry.get("bee.sync:database_ref")
    if not entry or type(entry.data) ~= "table" then return nil, "sync database reference unavailable" end
    local target: unknown = (entry.data :: {[string]: unknown}).resource_ref
    if type(target) ~= "string" or target == "" then return nil, "sync database reference is not linked" end
    return target, nil
end
return M

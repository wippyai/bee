-- The module's linked resources.  The host fills bee.threads:database_ref
-- through the target_db requirement; nothing here names a database directly.
local registry = require("registry")
local M = {}
local REFERENCE = "bee.threads:database_ref"
function M.database(): (string?, string?)
    local entry, err = registry.get(REFERENCE)
    if not entry then return nil, "thread database reference unavailable" end
    local data = entry.data
    local ref = type(data) == "table" and data.resource_ref or nil
    if type(ref) ~= "string" or ref == "" then return nil, "thread database reference is not linked" end
    return ref, nil
end
return M

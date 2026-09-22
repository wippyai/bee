-- MIT. Only the host links the staging store. Never take a DB/path from agents.
local registry = require("registry")
local bounds = require("bounds")
local M = {}
function M.database(): (string?, string?)
    local entry = registry.get("bee.governance:database_ref")
    local value = entry and bounds.object(entry.data) or nil
    local resource = value and bounds.id(value.resource_ref) or nil
    if not resource then return nil, "governance workspace database is not linked" end
    return resource, nil
end
return M

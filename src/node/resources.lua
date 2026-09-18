-- MIT. Host-linked SQL resource; no path or resource can arrive in a request.
local registry = require("registry")
local bounds = require("bounds")
local M = {}
function M.database(): (string?, string?)
    local entry, err = registry.get("bee.node:database_ref")
    if not entry then return nil, "node database reference is unavailable" end
    local data = bounds.object(entry.data)
    local resource = data and bounds.id(data.resource_ref) or nil
    if not resource then return nil, "node database reference is not linked" end
    return resource, nil
end
return M

-- MIT. The host-selected documentation filesystem. The module only resolves
-- its requirement link; the caller's policy determines whether that exact
-- registry entry and filesystem may be read.
local registry = require("registry")
local M = {}
M.CORPUS_REF = "bee.docs:corpus_ref"
function M.corpus(): (string?, string?)
    local entry, entry_error = registry.get(M.CORPUS_REF)
    if entry_error or not entry then return nil, "documentation corpus reference unavailable" end
    local data = entry.data
    local resource = type(data) == "table" and data.resource_ref or nil
    if type(resource) ~= "string" or resource == "" then return nil, "documentation corpus reference is not linked" end
    return resource, nil
end
return M

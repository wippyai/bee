-- MIT. Reads only host-selected registry resources named by Hub requirements.
local registry = require("registry")
local bounds = require("bounds")
local M = {}

M.PROCESS_HOST_REF = "bee.hub:process_host_ref"

function M.process_host(): (string?, string?)
    local linked, link_error = registry.get(M.PROCESS_HOST_REF)
    if not linked then return nil, tostring(link_error or "Hub process host is unavailable") end
    local data = type(linked.data) == "table" and linked.data or nil
    local host = data and bounds.id(data.host_ref) or nil
    if not host then return nil, "Hub process host is not linked" end
    local target, target_error = registry.get(host)
    if not target or target.kind ~= "process.host" then return nil, tostring(target_error or "Hub process host is unavailable") end
    return host, nil
end

return M

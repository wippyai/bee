-- SPDX-License-Identifier: MIT
-- Route discovery for the node's Hive supervisor: route entries map a prefix to
-- the node-local service that serves it.
local registry = require("registry")
local protocol = require("protocol")
local M = {}

type Found = {[string]: unknown}
type Find = (selector: {[string]: string}) -> ({Found}?, string?)

-- routes maps each route prefix to the node-local service name that serves it;
-- a failed registry read returns its error and no table.
function M.routes(find: Find?): ({[string]: string}?, string?)
    local found: {[string]: string} = {}
    local entries, problem = (find or registry.find)({["meta.type"] = protocol.ROUTE})
    if not entries then return nil, tostring(problem or "registry find returned no entries") end
    for _, entry in ipairs(entries) do
        local data: unknown = entry.data
        if type(data) == "table" and type(data.prefix) == "string" and type(data.name) == "string" then found[data.prefix] = data.name end
    end
    return found, nil
end

return M

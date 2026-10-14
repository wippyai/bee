-- MIT. Private authenticated authoring backend. Staging is not activation.
local security = require("security")
local system = require("system")
local protocol = require("protocol")
local staging = require("staging")
local resources = require("resources")
local transaction = require("transaction")
local source = require("source")
local bounds = require("bounds")
local M = {}
type Result = transaction.Result
function M.call(raw: unknown): Result
    if not security.can("bee.gov.workspace.execute", "bee.gov.binding:workspace_backend_call") then
        return transaction.failure("DENIED", "workspace backend is not authorized")
    end
    local request, invalid = protocol.decode(raw)
    if not request then return transaction.failure("INVALID", invalid or "invalid workspace request") end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated author is required") end
    if request.operation == "source" then
        local metadata = bounds.object(actor:meta())
        local workspace = metadata and bounds.id(metadata.workspace_id) or nil
        if not workspace then return transaction.failure("DENIED", "authenticated workspace is required") end
        local folder, folder_error = resources.workspace_folder(workspace)
        if not folder then return transaction.failure("UNAVAILABLE", folder_error or "workspace folder unavailable") end
        return source.read(folder, request)
    end
    local node, node_error = system.node.id()
    if not node or node_error or node == "" then return transaction.failure("UNAVAILABLE", "native node identity unavailable") end
    local resource, resource_error = resources.database()
    if not resource then return transaction.failure("UNAVAILABLE", resource_error or "workspace store unavailable") end
    local store, open_error = staging.open(resource, node)
    if not store then return transaction.failure("UNAVAILABLE", open_error or "workspace store unavailable") end
    -- Overlays a workspace's agents author belong to that workspace, held by
    -- governance for it: any principal acting for the workspace continues
    -- them. A principal bound to no workspace authors as itself.
    local metadata = bounds.object(actor:meta())
    local workspace = metadata and bounds.id(metadata.workspace_id) or nil
    local author = workspace and ("workspace:" .. workspace) or actor:id()
    local result = store:call(author, request)
    store:close()
    return result
end
return M

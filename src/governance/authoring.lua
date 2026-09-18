-- MIT. Private authenticated authoring backend. Staging is not activation.
local security = require("security")
local system = require("system")
local protocol = require("protocol")
local staging = require("staging")
local resources = require("resources")
local transaction = require("transaction")
local M = {}
type Result = transaction.Result
function M.call(raw: unknown): Result
    if not security.can("bee.governance.workspace.execute", "bee.governance:workspace_backend_call") then
        return transaction.failure("DENIED", "workspace backend is not authorized")
    end
    local request, invalid = protocol.decode(raw)
    if not request then return transaction.failure("INVALID", invalid or "invalid workspace request") end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated author is required") end
    local node, node_error = system.node.id()
    if not node or node_error or node == "" then return transaction.failure("UNAVAILABLE", "native node identity unavailable") end
    local resource, resource_error = resources.database()
    if not resource then return transaction.failure("UNAVAILABLE", resource_error or "workspace store unavailable") end
    local store, open_error = staging.open(resource, node)
    if not store then return transaction.failure("UNAVAILABLE", open_error or "workspace store unavailable") end
    local result = store:call(actor:id(), request)
    store:close()
    return result
end
return M

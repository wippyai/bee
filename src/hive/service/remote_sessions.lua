-- MIT. The gateway's host-selected remote session resolver: it asks the
-- destination node's own thread owner to resolve a node-qualified action
-- address to the thread and workspace it names there, over the existing Hive
-- call path. Resolution is discovery, never authority: the destination
-- re-checks workspace, send grant, target action and epoch when the send
-- arrives, and an unknown or unreachable address is reported as not found
-- rather than guessed.
local hive = require("hive")
local bounds = require("bounds")
local M = {}
M.OWNER_SERVICE = "bee.threads"
M.OPERATION = "bee.threads.service:inbox_resolve"
type Address = {node_id: string, action_id: string}
type Resolved = {thread_id: string, workspace_id: string, grant_epoch: integer}
-- resolve: one bounded call to the destination's own owner. A node the client
-- cannot reach, or an owner that refuses, is a not-found for the caller.
function M.resolve(address: Address): (Resolved?, string?)
    local node_id = bounds.id(address.node_id)
    local action_id = bounds.id(address.action_id)
    if not node_id or not action_id then return nil, "address must name a node and action" end
    local client, open_error = hive.open()
    if not client then return nil, open_error or "Hive client unavailable" end
    local reply = client:call({node_id = node_id, service_id = M.OWNER_SERVICE}, {operation_ref = M.OPERATION},
        {action_id = action_id, node_id = node_id}, {timeout = "15s"})
    client:close()
    if not reply.ok then
        local fault = reply.error
        return nil, fault and fault.message or "remote address is not resolvable"
    end
    local value = bounds.object(reply.value)
    local thread_id = value and bounds.id(value.thread_id)
    local workspace_id = value and bounds.id(value.workspace_id)
    local epoch = value and value.grant_epoch
    if not thread_id or not workspace_id or type(epoch) ~= "number" then
        return nil, "remote owner answered a malformed address resolution"
    end
    return {thread_id = thread_id, workspace_id = workspace_id, grant_epoch = math.floor(epoch)}, nil
end
return M

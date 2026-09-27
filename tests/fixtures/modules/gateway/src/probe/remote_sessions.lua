-- MIT. Test host resolver for the gateway's node-qualified send route.
local M = {}
type Address = {node_id: string, action_id: string}
type Resolved = {thread_id: string, workspace_id: string, grant_epoch: integer}
local WORKSPACE = "dddddddddddddddddddddddddddddddd"
function M.resolve(address: Address): (Resolved?, string?)
    if address.node_id ~= "remote-test-node" then return nil, "unknown test node" end
    if address.action_id == "remote-send-target" then
        return {thread_id = "remote-send-thread", workspace_id = WORKSPACE, grant_epoch = 17}, nil
    end
    if address.action_id == "remote-denied-target" then
        return {thread_id = "remote-denied-thread", workspace_id = WORKSPACE, grant_epoch = 23}, nil
    end
    return nil, "unknown test action"
end
return M

-- MIT. Remote session addressing for the gateway: resolving a node-qualified
-- {node_id, action_id} to the thread and workspace it names on its own node.
-- The resolver is host-selected; the default resolves nothing, so a
-- composition that links no transport answers a remote address as not found
-- rather than guessing a thread. This module holds no authority: the
-- destination owner re-checks every grant when the send arrives.
local M = {}
type Address = {node_id: string, action_id: string}
type Resolved = {thread_id: string, workspace_id: string, grant_epoch: integer}
function M.resolve(_: Address): (Resolved?, string?)
    return nil, "remote session addresses are not enabled on this node"
end
return M

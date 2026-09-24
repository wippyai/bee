-- MIT. Test principals bound to one workspace, as the broker binds a host-issued
-- application identity and the gateway binds a subject to its binding's
-- workspace. Workspace-scoped policies compare the resource with this metadata.
local security = require("security")
local M = {}
function M.actor(actor_id: string, workspace_id: unknown): security.Actor
    local meta: {[string]: string} = {}
    if type(workspace_id) == "string" then meta.workspace_id = workspace_id end
    return security.new_actor(actor_id, meta)
end
-- The workspace a request names; a principal acting on it is bound there.
function M.workspace(request: unknown): unknown
    if type(request) ~= "table" then return nil end
    return request.workspace_id
end
return M

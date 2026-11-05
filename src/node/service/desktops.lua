-- MIT. Desktop edits a display asks the node owner for, validated and stored.
local workspaces = require("workspaces")
local protocol = require("protocol")

local M = {}

-- use_workspace makes desktop id work in workspace_id; apps opened on it
-- from then on start there.
function M.use_workspace(id: unknown, workspace_id: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
    if type(workspace_id) ~= "string" or not workspaces.workspace(workspace_id) then return protocol.fail("no such workspace") end
    local used, err = workspaces.use_workspace(id, workspace_id)
    if not used then return protocol.fail(err or "workspace not used") end
    return protocol.ok({desktop = id, workspace = workspace_id})
end

function M.rename(id: unknown, title: unknown): protocol.Reply
    if type(id) ~= "string" or not workspaces.desktop(id) then return protocol.fail("no such desktop") end
    if type(title) ~= "string" or title == "" then return protocol.fail("a desktop needs a title") end
    local renamed, err = workspaces.rename_desktop(id, title)
    if not renamed then return protocol.fail(err or "desktop not renamed") end
    return protocol.ok({desktop = id, title = title})
end

return M

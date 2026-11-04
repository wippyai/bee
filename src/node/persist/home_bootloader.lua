-- MIT. Before the node's services start, the folder's own workspace takes the
-- folder's current path, so a moved folder recovers its applications and
-- keeps its sessions and profiles.
local system = require("system")
local workspaces = require("workspaces")

local M = {}

function M.run(): {status: string, message: string}
    local folder, cwd_error = system.process.cwd()
    if not folder then return {status = "error", message = "locate this bee's folder: " .. tostring(cwd_error)} end
    local home, follow_error = workspaces.follow(folder)
    if not home then return {status = "error", message = tostring(follow_error)} end
    return {status = "success", message = "folder workspace at " .. home.path}
end

return M

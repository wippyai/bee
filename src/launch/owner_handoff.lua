-- MIT. Serializable identity retained by the command while its code-bearing
-- controller is replaced. A PID is descriptive here, never authority.
local contract = require("contract")
type State = {version: integer, owner: string, workspace_id: string, desktop_id: string}
local M = {}
function M.pack(owner: string, workspace_id: string, desktop_id: string): State
    return {version = 1, owner = owner, workspace_id = workspace_id, desktop_id = desktop_id}
end
function M.decode(value: unknown, owner: string): State?
    if type(value) ~= "table" or value.version ~= 1 or value.owner ~= owner then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "owner" and key ~= "workspace_id" and key ~= "desktop_id" then return nil end
    end
    if type(value.workspace_id) ~= "string" or type(value.desktop_id) ~= "string" then return nil end
    local empty = value.workspace_id == "" and value.desktop_id == ""
    if not empty and (not contract.workspace_id(value.workspace_id) or not contract.workspace_id(value.desktop_id)) then return nil end
    return {version = 1, owner = owner, workspace_id = value.workspace_id, desktop_id = value.desktop_id}
end
return M

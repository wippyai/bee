-- MIT. Serializable client identity for an in-place code handoff.
local contract = require("contract")
type State = {version: integer, owner: string, host: string, workspace_id: string,
    display_id: string, connection_id: string, renderer_generation: string, controls_apps: boolean}
local M = {}
function M.pack(owner: string, host: string, workspace_id: string, display_id: string,
    connection_id: string, renderer_generation: string, controls_apps: boolean): State
    return {version = 1, owner = owner, host = host, workspace_id = workspace_id,
        display_id = display_id, connection_id = connection_id,
        renderer_generation = renderer_generation, controls_apps = controls_apps}
end
function M.decode(value: unknown, owner: string, host: string, workspace_id: string): State?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "owner" and key ~= "host" and key ~= "workspace_id"
            and key ~= "display_id" and key ~= "connection_id" and key ~= "renderer_generation"
            and key ~= "controls_apps" then return nil end
    end
    local saved_owner = contract.text(value.owner, 160)
    local saved_host = contract.text(value.host, 160)
    local saved_workspace = contract.workspace_id(value.workspace_id)
    local display = contract.workspace_id(value.display_id)
    local connection = contract.text(value.connection_id, 80)
    local generation = contract.text(value.renderer_generation, 80)
    if not saved_owner or saved_owner == "" or saved_owner ~= owner
        or not saved_host or saved_host == "" or saved_host ~= host
        or saved_workspace ~= workspace_id or not display
        or not connection or connection == "" or not generation or generation == ""
        or type(value.controls_apps) ~= "boolean" then return nil end
    return {version = 1, owner = saved_owner, host = saved_host, workspace_id = saved_workspace,
        display_id = display, connection_id = connection,
        renderer_generation = generation, controls_apps = value.controls_apps}
end
return M

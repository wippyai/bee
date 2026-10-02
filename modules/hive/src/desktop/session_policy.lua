-- MIT. Hive desktop session selection belongs to the owner contract.
local protocol = require("protocol")
local M = {}
type Request = protocol.PlanRequest
type Plan = protocol.SessionPlan

local function includes(values: {string}, selected: string): boolean
    for _, value in ipairs(values) do if value == selected then return true end end
    return false
end

function M.resolve(default_workspace: string?, request: Request): (Plan?, string?)
    local selected: string?
    if request.kind == "automatic" then
        if not default_workspace then return {kind = "choose_workspace"}, nil end
        selected = default_workspace
    else
        selected = request.workspace_id
    end
    if not selected then return nil, "session plan has no workspace" end
    if request.kind == "selection" then
        if not includes(request.desktops, request.desktop_id) then return nil, "selected desktop is unavailable" end
        return {kind = "attach", workspace_id = selected, desktop_id = request.desktop_id, mode = request.mode}, nil
    end
    for _, desktop in ipairs(request.desktops) do
        if not includes(request.excluded, desktop) then
            return {kind = "attach", workspace_id = selected, desktop_id = desktop, mode = request.mode}, nil
        end
    end
    if request.mode == "control" then return {kind = "allocate", workspace_id = selected}, nil end
    return nil, "selected owner has no display to observe"
end

return M

-- MIT. Layout changes derived from workspace decisions and live inventory.
local state = require("state")
local inventory = require("inventory")
type Assignment = {view_id: string, instance_id: string, display_id: string, revision: integer, pending: boolean}
type Changes = {add: {inventory.View}, remove: {string}}
local M = {}

-- Inputs have passed their boundary decoders. This computes presentation only;
-- the workspace host independently checks every controlling bind.
function M.plan(workspace_id: string, display_id: string, selected: {state.Target},
    live: {inventory.View}, assignments: {Assignment}): Changes
    local assigned: {[string]: Assignment} = {}
    for _, item in ipairs(assignments) do assigned[item.view_id .. "\0" .. item.instance_id] = item end
    local present: {[string]: boolean} = {}
    local removed: {string} = {}
    for _, target in ipairs(selected) do
        if target.workspace_id == workspace_id then
            local key = target.view_id .. "\0" .. target.instance_id
            present[key] = true
            local decision = assigned[key]
            if decision and decision.display_id ~= display_id then removed[#removed + 1] = target.tab_id end
        end
    end
    local added: {inventory.View} = {}
    for _, view in ipairs(live) do
        local key = view.view_id .. "\0" .. view.instance_id
        local decision = assigned[key]
        if view.workspace_id == workspace_id and decision and decision.display_id == display_id
            and not decision.pending and not present[key] then
            added[#added + 1] = view
            present[key] = true
        end
    end
    return {add = added, remove = removed}
end

return M

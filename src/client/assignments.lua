-- MIT. Layout changes derived from workspace decisions and live inventory.
local state = require("state")
local inventory = require("inventory")
local transfer = require("transfer")
type Assignment = transfer.Assignment
type MenuItem = {tab_id: string, instance_id: string, assignment_revision: integer, targets: {string}}
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

-- Choices are presentation of current admitted destinations. The host rechecks
-- destination availability and authority when a user selects one.
function M.menu(snapshot: transfer.Snapshot, selected: {state.Target}): {MenuItem}
    local destinations: {string} = {}
    for _, display in ipairs(snapshot.displays) do
        if display.display_id ~= snapshot.display_id and display.available and display.control then
            destinations[#destinations + 1] = display.display_id
        end
    end
    table.sort(destinations)
    local items: {MenuItem} = {}
    for _, target in ipairs(selected) do
        if target.workspace_id == snapshot.workspace_id then
            for _, assignment in ipairs(snapshot.items) do
                if assignment.view_id == target.view_id and assignment.instance_id == target.instance_id
                    and assignment.display_id == snapshot.display_id and not assignment.pending then
                    items[#items + 1] = {tab_id = target.tab_id, instance_id = target.instance_id,
                        assignment_revision = assignment.revision, targets = destinations}
                end
            end
        end
    end
    table.sort(items, function(left: MenuItem, right: MenuItem): boolean return left.tab_id < right.tab_id end)
    return items
end

return M

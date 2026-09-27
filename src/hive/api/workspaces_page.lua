-- MIT. Decode the workspace catalog page before exposing it through Hive.
local bounds = require("bounds")
local contract = require("contract")
local workspace_query = require("workspace_query")

type Workspace = {workspace_id: string, label: string}
type Page = {node_id: string, workspaces: {Workspace}, next_after: string?}

local M = {}

function M.decode(value: unknown, node_id: unknown, limit: integer): (Page?, string?)
    local checked_node = bounds.id(node_id)
    if not checked_node then return nil, "the local node has no identity" end
    if limit < 1 or limit > workspace_query.MAX_PAGE then return nil, "the workspace page size is invalid" end

    local page = bounds.object(value)
    if not page or bounds.fields(page, {"items", "next_after"}) then
        return nil, "the workspace catalog answered without a valid page"
    end
    local items, list_error = bounds.array(page.items, limit)
    if not items then return nil, "the workspace catalog answered a malformed page: " .. tostring(list_error) end

    local workspaces: {Workspace} = {}
    for index, raw in ipairs(items) do
        local row = bounds.object(raw)
        if row and bounds.fields(row, {"workspace_id", "label", "root_ref", "subpath", "state", "created_at", "last_used_at"}) then row = nil end
        local id = row and contract.workspace_id(row.workspace_id)
        local label = row and contract.text(row.label, workspace_query.MAX_LABEL)
        local root_ref = row and bounds.id(row.root_ref)
        local subpath = row and bounds.subpath(row.subpath)
        local state: string? = row and (row.state == "active" and "active" or (row.state == "archived" and "archived" or nil)) or nil
        local created_at = row and bounds.timestamp(row.created_at)
        local last_used_at = row and bounds.timestamp(row.last_used_at)
        if not id or label == nil or not root_ref or subpath == nil or not state or not created_at or not last_used_at then
            return nil, "the workspace catalog answered malformed row " .. tostring(index)
        end
        workspaces[index] = {workspace_id = id, label = label}
    end

    local next_after: string? = nil
    if page.next_after ~= nil then
        next_after = bounds.line(page.next_after, workspace_query.MAX_CURSOR)
        if not next_after then return nil, "the workspace catalog answered a malformed cursor" end
    end
    return {node_id = checked_node, workspaces = workspaces, next_after = next_after}, nil
end

return M

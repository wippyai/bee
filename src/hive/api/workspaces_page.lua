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

    local page = bounds.object(value)
    if not page or bounds.fields(page, {"items", "next_after"}) then
        return nil, "the workspace catalog answered without a valid page"
    end
    local items = page.items
    if type(items) ~= "table" then return nil, "the workspace catalog answered without rows" end

    local count = 0
    for key in pairs(items) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "the workspace catalog answered a malformed page"
        end
        count = count + 1
        if count > limit or count > workspace_query.MAX_PAGE then
            return nil, "the workspace catalog answered a malformed page"
        end
    end
    for index = 1, count do
        if items[index] == nil then return nil, "the workspace catalog answered a malformed page" end
    end

    local workspaces: {Workspace} = {}
    for index = 1, count do
        local row = bounds.object(items[index])
        local id = row and contract.workspace_id(row.workspace_id)
        local label = row and contract.text(row.label, workspace_query.MAX_LABEL)
        if not id or label == nil then return nil, "the workspace catalog answered a malformed row" end
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

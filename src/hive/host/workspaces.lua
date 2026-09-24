-- MIT. Open Hive operation: one page of this node's workspace catalog, so any
-- Hive member can see which workspaces a node holds and which it serves now.
-- It reads the catalog through its owner operations and returns only each
-- row's identity, label and whether a host serves it.
local funcs = require("funcs")
local process = require("process")
local system = require("system")
local bounds = require("bounds")
local M = {}
M.MAX_PAGE = 50
M.MAX_LABEL = 240
M.MAX_CURSOR = 2200
type Object = {[string]: unknown}
type Query = {label: string?, after: string?, limit: integer}
-- The request: an optional label prefix, cursor and page size.
function M.decode(value: unknown): (Query?, string?)
    if value ~= nil and not bounds.object(value) then return nil, "input must be an object" end
    local object: Object = bounds.object(value) or {}
    local extra = bounds.fields(object, {"label", "after", "limit"})
    if extra then return nil, extra end
    local query: Query = {label = nil, after = nil, limit = M.MAX_PAGE}
    if object.label ~= nil then
        local label = bounds.line(object.label, M.MAX_LABEL)
        if not label or label == "" then return nil, "label must be one nonempty line" end
        query.label = label
    end
    if object.after ~= nil then
        local after = bounds.line(object.after, M.MAX_CURSOR)
        if not after or after == "" then return nil, "after must be a cursor this operation returned" end
        query.after = after
    end
    if object.limit ~= nil then
        local limit = bounds.count(object.limit)
        if not limit or limit < 1 or limit > M.MAX_PAGE then return nil, "limit must be 1 to " .. tostring(M.MAX_PAGE) end
        query.limit = limit
    end
    return query, nil
end
-- A row's label: one bounded line. The folder workspace's row is unnamed.
local function row_label(value: unknown): string?
    if type(value) ~= "string" or #value > M.MAX_LABEL or value:find("%c") then return nil end
    return value
end
local function handle(value: unknown): Object
    local query, invalid = M.decode(value)
    if not query then error("invalid workspace listing: " .. tostring(invalid)) end
    local request: Object = {state = "active", limit = query.limit}
    if query.after then request.after = query.after end
    local target = "bee.workspace.catalog:list"
    if query.label then request.label = query.label; target = "bee.workspace.catalog:search" end
    local raw, call_error = funcs.call(target, request)
    if call_error then error("the workspace catalog did not answer: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then
        local failure = reply and bounds.object(reply.error)
        error("the workspace catalog refused the listing: " .. tostring(failure and failure.code))
    end
    local page = bounds.object(reply.value)
    local items = page and page.items
    if not page or type(items) ~= "table" then error("the workspace catalog answered without rows") end
    local workspaces: {Object} = {}
    for _, raw_row in ipairs(items :: {unknown}) do
        local row = bounds.object(raw_row)
        local id = row and bounds.id(row.workspace_id)
        local label = row and row_label(row.label)
        if not id or not label or #workspaces >= M.MAX_PAGE then error("the workspace catalog answered a malformed row") end
        workspaces[#workspaces + 1] = {workspace_id = id, label = label,
            served = process.registry.lookup("bee.workspace.host/" .. id) ~= nil}
    end
    local node_id = system.node.id()
    local result: Object = {node_id = type(node_id) == "string" and node_id or "", workspaces = workspaces}
    local next_after = bounds.line(page.next_after, M.MAX_CURSOR)
    if next_after and next_after ~= "" then result.next_after = next_after end
    return result
end
M.handle = handle
return M

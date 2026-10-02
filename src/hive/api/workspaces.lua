-- MIT. Open Hive operation: one page of this node's workspace catalog, so any
-- Hive member can see which workspaces a node holds and which it serves now.
-- It reads the catalog through its owner operations and returns only each
-- row's identity, label and whether a host serves it.
local funcs = require("funcs")
local process = require("process")
local system = require("system")
local bounds = require("bounds")
local workspace_query = require("workspace_query")
local workspace_page = require("workspace_page")
local M = {}
type Object = {[string]: unknown}

local function handle(value: unknown): Object
    local query, invalid = workspace_query.decode(value)
    if not query then error("invalid workspace listing: " .. tostring(invalid)) end
    local request: Object = {state = "active", limit = query.limit}
    if query.after then request.after = query.after end
    local target = "bee.workspace.binding:list"
    if query.label then request.label = query.label; target = "bee.workspace.binding:search" end
    local raw, call_error = funcs.call(target, request)
    if call_error then error("the workspace catalog did not answer: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then
        local failure = reply and bounds.object(reply.error)
        error("the workspace catalog refused the listing: " .. tostring(failure and failure.code))
    end
    local page, page_error = workspace_page.decode(reply.value, system.node.id(), query.limit)
    if not page then error(tostring(page_error)) end
    local workspaces: {Object} = {}
    for _, row in ipairs(page.workspaces) do
        workspaces[#workspaces + 1] = {workspace_id = row.workspace_id, label = row.label,
            served = process.registry.lookup("bee.workspace.host/" .. row.workspace_id) ~= nil}
    end
    local result: Object = {node_id = page.node_id, workspaces = workspaces}
    if page.next_after then result.next_after = page.next_after end
    return result
end
M.handle = handle
return M

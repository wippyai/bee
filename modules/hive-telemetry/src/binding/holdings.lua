-- MIT. Open Hive operation: one bounded page of the workspaces this node holds
-- live now, so any Hive member can see which node holds which workspace, each
-- host's phase and how many leases keep it live. It reads the node host
-- manager's own read model through its owner request; a missing manager is an
-- error, never an empty page, so an unreachable owner is never reported as
-- holding nothing. It grants nothing and changes no state.
local process = require("process")
local system = require("system")
local bounds = require("bounds")
local leases = require("leases")
local M = {}
M.MAX_PAGE = leases.MAX_HOLDINGS_PAGE
M.MAX_CURSOR = leases.MAX_CURSOR_BYTES
type Object = {[string]: unknown}
type Query = {after: string?, limit: integer}
-- The request: an optional cursor and page size, nothing else.
function M.decode(value: unknown): (Query?, string?)
    if value ~= nil and not bounds.object(value) then return nil, "input must be an object" end
    local object: Object = bounds.object(value) or {}
    local extra = bounds.fields(object, {"after", "limit"})
    if extra then return nil, extra end
    local query: Query = {after = nil, limit = M.MAX_PAGE}
    if object.after ~= nil then
        local after = bounds.line(object.after, M.MAX_CURSOR)
        if not after or after == "" then return nil, "after must be a cursor this operation returned" end
        query.after = after
    end
    if object.limit ~= nil then
        local limit = bounds.integer(object.limit)
        if not limit or limit < 1 or limit > M.MAX_PAGE then return nil, "limit must be 1 to " .. tostring(M.MAX_PAGE) end
        query.limit = limit
    end
    return query, nil
end
function M.handle(value: unknown): Object
    local query, invalid = M.decode(value)
    if not query then error("invalid holdings listing: " .. tostring(invalid)) end
    local page, read_error = leases.read_holdings({after = query.after, limit = query.limit}, "10s")
    if not page then error("the node host manager did not answer: " .. tostring(read_error)) end
    local node_id = system.node.id()
    local result: Object = {node_id = type(node_id) == "string" and node_id or "", workspaces = page.workspaces,
        has_more = page.has_more == true}
    if page.next_after then result.next_after = page.next_after end
    return result
end
return M

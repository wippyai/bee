-- MIT. Cluster workspace holdings: one bounded page of live workspace
-- holdings from each named node, aggregated for cluster telemetry. Each
-- node's count is that node's own answer through its open holdings
-- operation; a node that cannot be reached, refuses, or answers a malformed
-- page is reported unavailable, never as holding nothing. It grants nothing
-- and changes no state.
local bounds = require("bounds")
local types = require("types")
local client = require("client")
local M = {}
M.SERVICE = "bee.hive.telemetry"
M.HOLDINGS = "bee.hive.telemetry:holdings"
M.MAX_NODES = 8
M.MAX_PAGE = 50
M.TIMEOUT = "5s"
type Object = {[string]: unknown}
type Query = {nodes: {string}, limit: integer}
type NodeHoldings = {node_id: string, status: string, workspace_count: integer?, has_more: boolean?}
type Call = (types.OwnerRef, types.Target, {[string]: unknown}, {timeout: string?}) -> types.Reply
-- The request: one to eight node identities and a page size, nothing else.
function M.decode(value: unknown): (Query?, string?)
    if value ~= nil and not bounds.object(value) then return nil, "input must be an object" end
    local object: Object = bounds.object(value) or {}
    local extra = bounds.fields(object, {"nodes", "limit"})
    if extra then return nil, extra end
    local raw_nodes = object.nodes
    if type(raw_nodes) ~= "table" then return nil, "nodes must be a list of node identities" end
    local nodes: {string} = {}
    for _, raw in ipairs(raw_nodes :: {unknown}) do
        local node_id = bounds.id(raw)
        if not node_id then return nil, "nodes must be a list of node identities" end
        nodes[#nodes + 1] = node_id
        if #nodes > M.MAX_NODES then return nil, "nodes lists more than " .. tostring(M.MAX_NODES) .. " nodes" end
    end
    if #nodes == 0 then return nil, "nodes must name at least one node" end
    local limit = M.MAX_PAGE
    if object.limit ~= nil then
        local number = object.limit
        if type(number) ~= "number" or number ~= math.floor(number) or number < 1 or number > M.MAX_PAGE then
            return nil, "limit must be 1 to " .. tostring(M.MAX_PAGE)
        end
        limit = math.floor(number)
    end
    return {nodes = nodes, limit = limit}, nil
end
local function workspace_identity(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end
local function phase(value: unknown): string?
    if value ~= "starting" and value ~= "ready" and value ~= "stopping" then return nil end
    return value
end
-- One node's page as that node answered it: a strict count and its
-- continuation flag. A malformed page refuses the node, never an empty count.
function M.decode_page(value: unknown): ({workspace_count: integer, has_more: boolean}?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"node_id", "workspaces", "has_more", "next_after"}) then
        return nil, "holdings page is malformed"
    end
    if not bounds.id(object.node_id) then return nil, "holdings page is malformed" end
    if type(object.has_more) ~= "boolean" then return nil, "holdings page is malformed" end
    if type(object.workspaces) ~= "table" then return nil, "holdings page is malformed" end
    local rows = object.workspaces :: {[unknown]: unknown}
    local count = 0
    for key in pairs(rows) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "holdings page is malformed" end
        count = count + 1
    end
    if count > M.MAX_PAGE then return nil, "holdings page exceeds the page bound" end
    for index = 1, count do
        local row = bounds.object(rows[index])
        if not row or bounds.fields(row, {"workspace_id", "phase", "lease_count"}) then return nil, "holdings page is malformed" end
        local lease_count = row.lease_count
        if not workspace_identity(row.workspace_id) or not phase(row.phase)
            or type(lease_count) ~= "number" or lease_count ~= math.floor(lease_count) or lease_count < 0 then
            return nil, "holdings page is malformed"
        end
    end
    if object.next_after ~= nil and not workspace_identity(object.next_after) then return nil, "holdings page is malformed" end
    return {workspace_count = count, has_more = object.has_more == true}, nil
end
local function unavailable(node_id: string): NodeHoldings
    return {node_id = node_id, status = "unavailable"}
end
-- Ask each named node for one page through this node's supervisor and shape
-- the answers for presentation: a count per reachable node, unavailable
-- otherwise. The call reads only the named node's own operation; it grants
-- nothing on any node.
function M.aggregate(call: Call, query: Query): {NodeHoldings}
    local nodes: {NodeHoldings} = {}
    for _, node_id in ipairs(query.nodes) do
        local reply = call({node_id = node_id, service_id = M.SERVICE}, {operation_ref = M.HOLDINGS},
            {limit = query.limit}, {timeout = M.TIMEOUT})
        if not reply.ok or type(reply.value) ~= "table" then
            nodes[#nodes + 1] = unavailable(node_id)
        else
            local page, invalid = M.decode_page(reply.value)
            if not page then
                nodes[#nodes + 1] = unavailable(node_id)
            else
                nodes[#nodes + 1] = {node_id = node_id, status = "ok",
                    workspace_count = page.workspace_count, has_more = page.has_more}
            end
        end
    end
    return nodes
end
function M.handle(value: unknown): Object
    local query, invalid = M.decode(value)
    if not query then error("invalid cluster holdings: " .. tostring(invalid)) end
    local harness, open_error = client.open()
    if not harness then error("the hive supervisor is not running: " .. tostring(open_error)) end
    local bound: Call = function(owner: types.OwnerRef, target: types.Target, input: {[string]: unknown},
        options: {timeout: string?}): types.Reply
        return harness:call(owner, target, input, options)
    end
    local nodes = M.aggregate(bound, query)
    harness:close()
    return {nodes = nodes}
end
return M

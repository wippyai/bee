-- MIT. Cluster workspace holdings: one bounded page of live workspace
-- holdings from each named node, aggregated for cluster telemetry. Each
-- node's count is that node's own answer through its open holdings
-- operation; a node that cannot be reached, refuses, or answers a malformed
-- page is reported unavailable, never as holding nothing. It grants nothing
-- and changes no state.
local bounds = require("bounds")
local contract = require("contract")
local types = require("types")
local client = require("client")
local system = require("system")
local M = {}
M.SERVICE = "bee.hive.telemetry"
M.HOLDINGS = "bee.hive.telemetry:holdings"
M.MAX_NODES = 8
M.MAX_MEMBERS = bounds.MAX_ARRAY_ITEMS
M.MAX_PAGE = 50
M.MAX_ADDRESS_BYTES = 200
M.TIMEOUT = "5s"
type Object = {[string]: unknown}
type Query = {nodes: {string}, limit: integer}
type Phase = "starting" | "ready" | "stopping"
type Direction = "outbound" | "inbound"
type LinkState = {connected: false} | {connected: true, direction: Direction, remote_address: string}
type LinkStates = {[string]: LinkState}
type LinkFields = {connected: false, direction: nil, remote_address: nil}
    | {connected: true, direction: Direction, remote_address: string}
type NodeHoldings =
    {node_id: string, status: "ok", connected: false, direction: nil, remote_address: nil, workspace_count: integer, has_more: boolean}
    | {node_id: string, status: "ok", connected: true, direction: Direction, remote_address: string, workspace_count: integer, has_more: boolean}
    | {node_id: string, status: "unavailable", connected: false, direction: nil, remote_address: nil}
    | {node_id: string, status: "unavailable", connected: true, direction: Direction, remote_address: string}
type Call = (types.OwnerRef, types.Target, {[string]: unknown}, {timeout: string?}) -> types.Reply
type MemberListing = () -> (unknown, unknown)
-- The request: one to eight node identities and a page size, nothing else.
function M.decode(value: unknown): (Query?, string?)
    if value ~= nil and not bounds.object(value) then return nil, "input must be an object" end
    local object: Object = bounds.object(value) or {}
    local extra = bounds.fields(object, {"nodes", "limit"})
    if extra then return nil, extra end
    local raw_nodes = object.nodes
    local rows = bounds.array(raw_nodes, M.MAX_NODES)
    if not rows then return nil, "nodes must be a dense list of at most " .. tostring(M.MAX_NODES) .. " node identities" end
    local nodes: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local node_id = bounds.id(raw)
        if not node_id or seen[node_id] then return nil, "nodes must be a list of distinct node identities" end
        seen[node_id] = true
        nodes[#nodes + 1] = node_id
    end
    if #nodes == 0 then return nil, "nodes must name at least one node" end
    local limit = M.MAX_PAGE
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > M.MAX_PAGE then
            return nil, "limit must be 1 to " .. tostring(M.MAX_PAGE)
        end
        limit = number
    end
    return {nodes = nodes, limit = limit}, nil
end
-- Decode the pinned runtime's system.cluster.members() records. A missing
-- link means disconnected; a present link carries the local node's direction
-- and the remote socket address it sees.
function M.decode_members(value: unknown): (LinkStates?, string?)
    local rows = bounds.array(value, M.MAX_MEMBERS)
    if not rows then return nil, "cluster membership must be a dense list of at most " .. tostring(M.MAX_MEMBERS) .. " nodes" end
    local links: LinkStates = {}
    for _, raw in ipairs(rows) do
        local member = bounds.object(raw)
        if not member or bounds.fields(member, {"id", "is_local", "addr", "meta", "link"}) then
            return nil, "cluster membership contains a malformed node"
        end
        local node_id = bounds.id(member.id)
        if not node_id or type(member.is_local) ~= "boolean" or links[node_id] ~= nil then
            return nil, "cluster membership contains a malformed or duplicate node"
        end
        if member.addr ~= nil and not bounds.line(member.addr, M.MAX_ADDRESS_BYTES) then
            return nil, "cluster membership contains a malformed node address"
        end
        if member.meta ~= nil and not bounds.object(member.meta) then
            return nil, "cluster membership contains malformed node metadata"
        end
        local state: LinkState = {connected = false}
        if member.link ~= nil then
            local link = bounds.object(member.link)
            if not link or bounds.fields(link, {"remote", "dialed"}) then
                return nil, "cluster membership contains a malformed node link"
            end
            local remote = bounds.line(link.remote, M.MAX_ADDRESS_BYTES)
            if not remote or type(link.dialed) ~= "boolean" then
                return nil, "cluster membership contains a malformed node link"
            end
            local direction: Direction
            if link.dialed then direction = "outbound" else direction = "inbound" end
            state = {connected = true, direction = direction, remote_address = remote}
        end
        links[node_id] = state
    end
    return links, nil
end
function M.read_links(listing: MemberListing): (LinkStates?, string?)
    local raw_members, membership_error = listing()
    if membership_error ~= nil then return nil, "cluster membership unavailable: " .. tostring(membership_error) end
    local links, malformed = M.decode_members(raw_members)
    if not links then return nil, "invalid cluster membership: " .. tostring(malformed) end
    return links, nil
end
local function phase(value: unknown): Phase?
    if value ~= "starting" and value ~= "ready" and value ~= "stopping" then return nil end
    return value
end
-- One node's page as that node answered it: a strict count and its
-- continuation flag. A malformed page refuses the node, never an empty count.
function M.decode_page(value: unknown, expected_node_id: string): ({workspace_count: integer, has_more: boolean}?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"node_id", "workspaces", "has_more", "next_after"}) then
        return nil, "holdings page is malformed"
    end
    if object.node_id ~= expected_node_id then return nil, "holdings page names another node" end
    if type(object.has_more) ~= "boolean" then return nil, "holdings page is malformed" end
    local rows = bounds.array(object.workspaces, M.MAX_PAGE)
    if not rows then return nil, "holdings page is malformed" end
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        if not row or bounds.fields(row, {"workspace_id", "phase", "lease_count"}) then return nil, "holdings page is malformed" end
        local workspace_id = contract.workspace_id(row.workspace_id)
        local lease_count = bounds.count(row.lease_count)
        if not workspace_id or seen[workspace_id] or not phase(row.phase) or lease_count == nil then
            return nil, "holdings page is malformed"
        end
        seen[workspace_id] = true
    end
    local next_after = object.next_after == nil and nil or contract.workspace_id(object.next_after)
    if (object.next_after ~= nil and not next_after) or (object.has_more == true) ~= (next_after ~= nil) then
        return nil, "holdings page is malformed"
    end
    return {workspace_count = #rows, has_more = object.has_more}, nil
end
local function link_fields(node_id: string, links: LinkStates): LinkFields
    local state = links[node_id]
    if not state or not state.connected then
        return {connected = false, direction = nil, remote_address = nil}
    end
    return {connected = true, direction = state.direction, remote_address = state.remote_address}
end
local function unavailable(node_id: string, link: LinkFields): NodeHoldings
    if link.connected then
        return {node_id = node_id, status = "unavailable", connected = true,
            direction = link.direction, remote_address = link.remote_address}
    end
    return {node_id = node_id, status = "unavailable", connected = false, direction = nil, remote_address = nil}
end
local function available(node_id: string, page: {workspace_count: integer, has_more: boolean}, link: LinkFields): NodeHoldings
    if link.connected then
        return {node_id = node_id, status = "ok", connected = true, direction = link.direction,
            remote_address = link.remote_address, workspace_count = page.workspace_count, has_more = page.has_more}
    end
    return {node_id = node_id, status = "ok", connected = false, direction = nil, remote_address = nil,
        workspace_count = page.workspace_count, has_more = page.has_more}
end
-- Ask each named node for one page through this node's supervisor and shape
-- the answers for presentation: a count per reachable node, unavailable
-- otherwise. Link state comes from a single typed local membership snapshot;
-- the call reads only the named node's own operation and grants nothing.
function M.aggregate(call: Call, query: Query, links: LinkStates): {NodeHoldings}
    local nodes: {NodeHoldings} = {}
    for _, node_id in ipairs(query.nodes) do
        local link = link_fields(node_id, links)
        local reply = call({node_id = node_id, service_id = M.SERVICE}, {operation_ref = M.HOLDINGS},
            {limit = query.limit}, {timeout = M.TIMEOUT})
        if not reply.ok or type(reply.value) ~= "table" then
            nodes[#nodes + 1] = unavailable(node_id, link)
        else
            local page = M.decode_page(reply.value, node_id)
            if not page then
                nodes[#nodes + 1] = unavailable(node_id, link)
            else
                nodes[#nodes + 1] = available(node_id, page, link)
            end
        end
    end
    return nodes
end
function M.handle(value: unknown): Object
    local query, invalid = M.decode(value)
    if not query then error("invalid cluster holdings: " .. tostring(invalid)) end
    local listing: MemberListing = function(): (unknown, unknown) return system.cluster.members() end
    local links, membership_error = M.read_links(listing)
    if not links then error(tostring(membership_error)) end
    local harness, open_error = client.open()
    if not harness then error("the hive supervisor is not running: " .. tostring(open_error)) end
    local bound: Call = function(owner: types.OwnerRef, target: types.Target, input: {[string]: unknown},
        options: {timeout: string?}): types.Reply
        return harness:call(owner, target, input, options)
    end
    local nodes = M.aggregate(bound, query, links)
    harness:close()
    return {nodes = nodes}
end
return M

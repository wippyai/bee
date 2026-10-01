-- MIT.
local bounds = require("bounds")
local types = require("types")
local M = {}
M.MAX_NODES = 64
type Object = {[string]: unknown}
type Member = {node_id: string, online: boolean}
type Summary = {node_id: string, name: string, running_sessions: integer, pending_approvals: integer}
type Node = {node_id: string, name: string, online: boolean, status: string, running_sessions: integer?, pending_approvals: integer?}
type Call = (types.OwnerRef, types.Target, Object, {timeout: string?}) -> types.Reply
function M.query(value: unknown, detail: boolean): ({node_id: string?}?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, detail and {"node_id"} or {}) then return nil, "invalid status query" end
    local node = bounds.id(object.node_id)
    if detail and not node then return nil, "detail requires a node identity" end
    return {node_id = node}, nil
end
function M.members(value: unknown, peers: {string}, local_node: string): ({Member}?, string?)
    local rows = bounds.array(value, M.MAX_NODES)
    if not rows then return nil, "cluster membership is unavailable or malformed" end
    local known: {[string]: Member} = {[local_node] = {node_id = local_node, online = true}}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item = bounds.object(raw)
        local id = item and bounds.id(item.id) or nil
        if not item or not id or seen[id] or type(item.is_local) ~= "boolean" or item.is_local ~= (id == local_node)
            or bounds.fields(item, {"id", "is_local", "addr", "meta", "link"}) then return nil, "malformed cluster member" end
        seen[id] = true
        local meta = item.meta == nil and {} or bounds.object(item.meta)
        if not meta or (meta["bee.role"] ~= nil and type(meta["bee.role"]) ~= "string") then return nil, "malformed node metadata" end
        local connected = false
        if item.link ~= nil then
            local link = bounds.object(item.link)
            if not link or bounds.fields(link, {"remote", "dialed"}) or not bounds.line(link.remote, 200)
                or type(link.dialed) ~= "boolean" then return nil, "malformed node link" end
            connected = true
        end
        if meta["bee.role"] ~= "client" then known[id] = {node_id = id, online = id == local_node or connected} end
    end
    for _, peer in ipairs(peers) do
        if not bounds.id(peer) then return nil, "malformed enrolled peer" end
        if not known[peer] then known[peer] = {node_id = peer, online = false} end
    end
    local result: {Member} = {}
    for _, node in pairs(known) do result[#result + 1] = node end
    if #result > M.MAX_NODES then return nil, "too many Hive nodes" end
    table.sort(result, function(a: Member, b: Member): boolean return a.node_id < b.node_id end)
    return result, nil
end
function M.decode_summary(value: unknown, expected: string): Summary?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"node_id", "name", "running_sessions", "pending_approvals"}) then return nil end
    local name = bounds.line(object.name, 80)
    local running, pending = bounds.count(object.running_sessions), bounds.count(object.pending_approvals)
    if object.node_id ~= expected or not name or running == nil or pending == nil then return nil end
    return {node_id = expected, name = name, running_sessions = running, pending_approvals = pending}
end
function M.aggregate(call: Call, members: {Member}): {Node}
    local result: {Node} = {}
    for _, member in ipairs(members) do
        local reply = call({node_id = member.node_id, service_id = "bee.hive.telemetry"},
            {operation_ref = "bee.hive.telemetry:node_summary"}, {}, {timeout = "2s"})
        local summary = reply.ok and M.decode_summary(reply.value, member.node_id) or nil
        result[#result + 1] = {node_id = member.node_id, name = summary and summary.name or member.node_id,
            online = member.online, status = summary and "ok" or "unavailable",
            running_sessions = summary and summary.running_sessions or nil,
            pending_approvals = summary and summary.pending_approvals or nil}
    end
    return result
end
return M

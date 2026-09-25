-- MIT. Host-selected enrollment for the Hive supervisor. The host writes one
-- typed registry entry naming its local client nodes and its Hive peers; this
-- library only reads and diffs it. It creates no transport, principal or grant,
-- and never admits a node on its own.
local bounds = require("bounds")
local M = {}
type State = {configured_nodes: {[string]: boolean}}
-- ENTRY is the host-owned registry entry. A host overlay replaces its data with
-- the nodes it admits; discovery and membership never write it.
M.ENTRY = "bee.hive_host.supervisor:enrollment_nodes"
M.TYPE = "bee.hive_host.supervisor_enrollment"
-- nodes are local clients of this owner: they reach the desktop bridge and the
-- invite operations. peers are nodes of this node's hive: they establish a
-- supervisor session and reach only the operations the exposure levels admit.
type Enrollment = {nodes: {string}, peers: {string}}
-- decode validates the host-owned lists with the same bounds the boot set obeys.
-- Shape is exact: only `nodes` and `peers`, dense, bounded, identifiers only, and
-- no node in both roles.
function M.decode(value: unknown): (Enrollment?, string?)
    local object = bounds.object(value)
    if not object then return nil, "enrollment must be an object" end
    local unknown = bounds.fields(object, {"nodes", "peers"})
    if unknown then return nil, unknown end
    local nodes, nodes_error = bounds.ids(object.nodes)
    if not nodes then return nil, "nodes: " .. tostring(nodes_error) end
    local peers, peers_error = bounds.ids(object.peers)
    if not peers then return nil, "peers: " .. tostring(peers_error) end
    local seen: {[string]: boolean} = {}
    for position, node in ipairs(nodes) do
        if seen[node] then return nil, "nodes[" .. tostring(position) .. "] repeats a node" end
        seen[node] = true
    end
    for position, node in ipairs(peers) do
        if seen[node] then return nil, "peers[" .. tostring(position) .. "] repeats a node" end
        seen[node] = true
    end
    return {nodes = nodes, peers = peers}, nil
end
-- desired returns every node the enrollment admits, in either role.
function M.desired(enrollment: Enrollment): {string}
    local result: {string} = {}
    for _, node in ipairs(enrollment.nodes) do result[#result + 1] = node end
    for _, node in ipairs(enrollment.peers) do result[#result + 1] = node end
    return result
end
-- set returns the members of one enrollment list that the supervisor actually
-- configured and the boot set does not own, so a refused enrollment is never
-- presented as admitted and a boot peer never takes an enrolled role.
function M.set(list: {string}, boot: {[string]: boolean}, configured: {[string]: boolean}): {[string]: boolean}
    local result: {[string]: boolean} = {}
    for _, node in ipairs(list) do
        if configured[node] and not boot[node] then result[node] = true end
    end
    return result
end
-- configured_view returns the current configured set from peer state, so the
-- reconcile compares desire against what the supervisor actually admits.
function M.configured_view(state: State): {[string]: boolean}
    return state.configured_nodes
end
-- diff returns the nodes to enroll and to retire to reach the desired set.
-- Boot-configured nodes are authoritative and always excluded from both lists,
-- so an enrollment edit can never retire a boot peer or re-enroll it.
function M.diff(desired: {string}, boot: {[string]: boolean}, configured: {[string]: boolean}): ({string}, {string})
    local wanted: {[string]: boolean} = {}
    for _, node in ipairs(desired) do wanted[node] = true end
    local enroll: {string} = {}
    for _, node in ipairs(desired) do
        local candidate: string = node
        if not boot[candidate] and not configured[candidate] then enroll[#enroll + 1] = candidate end
    end
    local retire: {string} = {}
    for node in pairs(configured) do
        local candidate: string = node
        if not boot[candidate] and not wanted[candidate] then retire[#retire + 1] = candidate end
    end
    table.sort(retire)
    return enroll, retire
end
return M

-- MIT. Host-selected local client enrollment for the Hive supervisor. The host
-- writes one typed registry entry; this library only reads and diffs it. It
-- creates no transport, principal or grant, and never admits a node on its own.
local bounds = require("bounds")
local M = {}
type State = {configured_nodes: {[string]: boolean}}
-- ENTRY is the host-owned registry entry. A host overlay replaces its data with
-- the local client nodes it admits; discovery and membership never write it.
M.ENTRY = "bee.hive.supervisor:enrollment_nodes"
M.TYPE = "bee.hive.supervisor_enrollment"
type Enrollment = {nodes: {string}}
-- decode validates the host-owned list with the same bounds the boot set obeys.
-- Shape is exact: only `nodes`, dense, bounded, identifiers only.
function M.decode(value: unknown): (Enrollment?, string?)
    local object = bounds.object(value)
    if not object then return nil, "enrollment must be an object" end
    local unknown = bounds.fields(object, {"nodes"})
    if unknown then return nil, unknown end
    local nodes, nodes_error = bounds.ids(object.nodes)
    if not nodes then return nil, "nodes: " .. tostring(nodes_error) end
    local seen: {[string]: boolean} = {}
    for position, node in ipairs(nodes) do
        if seen[node] then return nil, "nodes[" .. tostring(position) .. "] repeats a node" end
        seen[node] = true
    end
    return {nodes = nodes}, nil
end
-- configured_view returns the current configured set from peer state, so the
-- reconcile compares desire against what the supervisor actually admits.
function M.configured_view(state: State): {[string]: boolean}
    return state.configured_nodes
end
-- enrolled returns the nodes the enrollment admitted: configured, and not owned
-- by the boot set.
function M.enrolled(boot: {[string]: boolean}, configured: {[string]: boolean}): {[string]: boolean}
    local nodes: {[string]: boolean} = {}
    for node in pairs(configured) do
        local candidate: string = node
        if not boot[candidate] then nodes[candidate] = true end
    end
    return nodes
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

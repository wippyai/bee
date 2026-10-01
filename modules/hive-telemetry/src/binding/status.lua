-- MIT.
local system = require("system")
local registry = require("registry")
local bounds = require("bounds")
local status = require("status")
local client = require("client")
local types = require("types")
local access = require("capability_access")
local gateway = require("capability_gateway")
type Object = {[string]: unknown}
local function read(value: unknown, detail: boolean): Object
    local caller, record, live, refusal = access.granted()
    local allowed, denied = gateway.contract(record, caller, "bee.hive.telemetry.binding:status",
        detail and "detail" or "snapshot", live)
    if refusal or not allowed then error("DENIED: " .. (denied or "no live status grant")) end
    local query, invalid = status.query(value, detail)
    if not query then error(invalid or "invalid status query") end
    local local_node, node_error = system.node.id()
    if not local_node then error(tostring(node_error)) end
    local ref = registry.get("bee.hive.telemetry:peer_source")
    local data = ref and bounds.object(ref.data) or nil
    local resource = data and bounds.id(data.resource_ref) or nil
    if not resource then error("Hive peer source is not linked") end
    local source = registry.get(resource)
    local source_data = source and bounds.object(source.data) or nil
    local peers, peers_error = bounds.ids(source_data and source_data.peers)
    if not peers then error(peers_error or "Hive enrollment is unavailable") end
    local raw, member_error = system.cluster.members()
    if member_error then error(tostring(member_error)) end
    local members, malformed = status.members(raw, peers, local_node)
    if not members then error(malformed or "Hive membership unavailable") end
    if detail then
        local selected: {status.Member} = {}
        for _, member in ipairs(members) do if member.node_id == query.node_id then selected[1] = member end end
        if #selected == 0 then error("node is not in this Hive") end
        members = selected
    end
    local connection, open_error = client.open()
    if not connection then error(open_error or "Hive supervisor unavailable") end
    local call = function(owner: types.OwnerRef, target: types.Target, input: Object, options: {timeout: string?}): types.Reply
        return connection:call(owner, target, input, options)
    end
    local result = status.aggregate(call, members)
    connection:close()
    if detail then return {node = result[1]} end
    return {nodes = result}
end
local function snapshot(value: unknown): Object return read(value, false) end
local function detail(value: unknown): Object return read(value, true) end
return {snapshot = snapshot, detail = detail}

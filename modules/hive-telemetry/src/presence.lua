-- MIT. Open operation: who this node is and whether it is ready.
local system = require("system")
local time = require("time")
local types = require("types")
local function handle(_: unknown): {[string]: unknown}
    local node_id, node_error = system.node.id()
    if node_error or not node_id then node_id = "" end
    local role, role_error = system.node.role()
    if role_error or not role then role = "" end
    local size, size_error = system.cluster.size()
    if size_error or type(size) ~= "number" then size = 1 end
    return {protocol_revision = types.REVISION, node_id = node_id, role = role, cluster_size = math.floor(size),
        sampled_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")}
end
return {handle = handle}

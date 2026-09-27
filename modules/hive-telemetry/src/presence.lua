-- MIT. Open operation: who this node is and whether it is ready.
local system = require("system")
local types = require("types")
local sampling = require("sampling")
local time_format = require("time_format")
local function handle(_: unknown): {[string]: unknown}
    local sample, sample_error = sampling.presence({
        node_id = function(): (unknown, unknown?) return system.node.id() end,
        role = function(): (unknown, unknown?) return system.node.role() end,
        cluster_size = function(): (unknown, unknown?) return system.cluster.size() end,
        sampled_at = time_format.now,
    }, types.REVISION)
    if not sample then error(tostring(sample_error)) end
    return sample
end
return {handle = handle}

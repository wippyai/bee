-- Typed decoders for runtime samples. A failed required source has no value.
local bounds = require("bounds")
local M = {}

type PresenceSources = {
    node_id: () -> (unknown, unknown?),
    role: () -> (unknown, unknown?),
    cluster_size: () -> (unknown, unknown?),
    sampled_at: () -> string,
}
type StatsSources = {
    memory: () -> (unknown, unknown?),
    goroutines: () -> (unknown, unknown?),
    cpu_count: () -> (unknown, unknown?),
    sampled_at: () -> string,
}
type PresenceSample = {protocol_revision: string, node_id: string, role: string, cluster_size: integer, sampled_at: string}
type StatsSample = {memory: {[string]: integer}, goroutines: integer, cpu_count: integer, sampled_at: string}

local function failed(name: string, message: unknown): string
    return name .. " sampling failed: " .. tostring(message)
end

function M.presence(sources: PresenceSources, revision: string): (PresenceSample?, string?)
    local raw_node, node_error = sources.node_id()
    if node_error then return nil, failed("node identity", node_error) end
    local node_id = bounds.id(raw_node)
    if not node_id then return nil, "node identity sampling failed: invalid node id" end

    local raw_role, role_error = sources.role()
    if role_error then return nil, failed("node role", role_error) end
    local role = bounds.line(raw_role, 32)
    if not role then return nil, "node role sampling failed: invalid role" end

    local raw_size, size_error = sources.cluster_size()
    if size_error then return nil, failed("cluster size", size_error) end
    local cluster_size = bounds.integer(raw_size)
    if not cluster_size or cluster_size < 1 then return nil, "cluster size sampling failed: invalid cluster size" end

    local sampled_at = bounds.timestamp(sources.sampled_at())
    if not sampled_at then return nil, "sample timestamp is invalid" end
    return {protocol_revision = revision, node_id = node_id, role = role, cluster_size = cluster_size, sampled_at = sampled_at}, nil
end

function M.stats(sources: StatsSources): (StatsSample?, string?)
    local raw_memory, memory_error = sources.memory()
    if memory_error then return nil, failed("memory", memory_error) end
    local sample = bounds.object(raw_memory)
    if not sample then return nil, "memory sampling failed: invalid statistics" end
    local memory: {[string]: integer} = {}
    for _, name in ipairs({"alloc", "total_alloc", "sys", "heap_alloc", "heap_objects", "num_gc"}) do
        local value: unknown = sample[name]
        if value ~= nil then
            local count = bounds.count(value)
            if not count then return nil, "memory sampling failed: invalid " .. name end
            memory[name] = count
        end
    end
    if memory.heap_alloc == nil then return nil, "memory sampling failed: heap allocation unavailable" end

    local raw_goroutines, goroutine_error = sources.goroutines()
    if goroutine_error then return nil, failed("goroutine count", goroutine_error) end
    local goroutines = bounds.count(raw_goroutines)
    if not goroutines then return nil, "goroutine count sampling failed: invalid count" end

    local raw_cpus, cpu_error = sources.cpu_count()
    if cpu_error then return nil, failed("CPU count", cpu_error) end
    local cpu_count = bounds.count(raw_cpus)
    if not cpu_count or cpu_count < 1 then return nil, "CPU count sampling failed: invalid count" end

    local sampled_at = bounds.timestamp(sources.sampled_at())
    if not sampled_at then return nil, "sample timestamp is invalid" end
    return {memory = memory, goroutines = goroutines, cpu_count = cpu_count, sampled_at = sampled_at}, nil
end

return M

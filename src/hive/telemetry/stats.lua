-- MIT. Open operation: bounded runtime statistics, numbers only.
local system = require("system")
local time = require("time")
local function handle(_: unknown): {[string]: unknown}
    local memory: {[string]: integer} = {}
    local sample, sample_error = system.memory.stats()
    if not sample_error and type(sample) == "table" then
        for _, name in ipairs({"alloc", "total_alloc", "sys", "heap_alloc", "heap_objects", "num_gc"}) do
            local value: unknown = sample[name]
            if type(value) == "number" then memory[name] = math.floor(value) end
        end
    end
    local goroutines, goroutines_error = system.runtime.goroutines()
    if goroutines_error or type(goroutines) ~= "number" then goroutines = 0 end
    local cpus, cpus_error = system.runtime.cpu_count()
    if cpus_error or type(cpus) ~= "number" then cpus = 0 end
    return {memory = memory, goroutines = math.floor(goroutines), cpu_count = math.floor(cpus),
        sampled_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")}
end
return {handle = handle}

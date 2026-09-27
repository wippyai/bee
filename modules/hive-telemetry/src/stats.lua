-- MIT. Open operation: bounded runtime statistics, numbers only.
local system = require("system")
local sampling = require("sampling")
local clock = require("clock")
local function handle(_: unknown): {[string]: unknown}
    local sample, sample_error = sampling.stats({
        memory = function(): (unknown, unknown?) return system.memory.stats() end,
        goroutines = function(): (unknown, unknown?) return system.runtime.goroutines() end,
        cpu_count = function(): (unknown, unknown?) return system.runtime.cpu_count() end,
        sampled_at = clock.now,
    })
    if not sample then error(tostring(sample_error)) end
    return sample
end
return {handle = handle}

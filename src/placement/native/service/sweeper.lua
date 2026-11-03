-- SPDX-License-Identifier: MIT
local worker = require("worker")
local service = require("service")
local process = require("process")
local bounds = require("bounds")
-- watch monitors the managed window owners a sweep reports, so an owner
-- that ends wakes the next sweep. It reports whether every owner is watched;
-- one already gone is not, and the sweep runs again to prove its child.
local function watch(swept: service.Reply): boolean
    local value = bounds.object(swept.value)
    for _, owner in ipairs(bounds.ids(value and value.window_owners, true) or {}) do
        local monitored, problem = process.monitor(owner)
        if not monitored and not (problem and problem:kind() == errors.ALREADY_EXISTS) then return false end
    end
    return true
end
local function main()
    worker.run({name = service.SWEEPER_NAME, demand = true, active = service.pending, exits = true,
        every = tostring(service.SWEEP_INTERVAL_MS) .. "ms", pass = function(): boolean
            local swept = service.sweep()
            if swept.ok and not watch(swept) then swept = service.sweep() end
            return swept.ok
        end})
end
return {main = main}

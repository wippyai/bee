-- SPDX-License-Identifier: MIT
local worker = require("worker")
local service = require("service")
local function main()
    worker.run({name = service.SWEEPER_NAME, demand = true, active = service.pending,
        every = tostring(service.SWEEP_INTERVAL_MS) .. "ms", pass = function(): boolean
            return service.sweep().ok
        end})
end
return {main = main}

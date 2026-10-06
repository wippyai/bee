-- SPDX-License-Identifier: MIT
local worker = require("worker")
local service = require("service")
local function main()
    worker.run({name = service.SWEEPER_NAME, every = tostring(service.SWEEP_INTERVAL_MS) .. "ms", pass = function(): boolean
        service.sweep()
        return true
    end})
end
return {main = main}

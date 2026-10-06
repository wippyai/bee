-- MIT. Placement supervision: every interval, reconcile each live attempt so
-- its leases are renewed and a revoked grant or projection is enforced within
-- a bounded time.
local worker = require("worker")
local service = require("service")
local function main()
    worker.run({name = service.SWEEPER_NAME, every = tostring(service.SWEEP_INTERVAL_MS) .. "ms", pass = function(): boolean
        service.sweep()
        return true
    end})
end
return {main = main}

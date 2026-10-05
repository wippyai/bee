-- MIT. Placement supervision: every interval, reconcile each live attempt
-- so a revoked grant or projection is enforced within a bounded time.
local process = require("process")
local channel = require("channel")
local time = require("time")
local service = require("service")
local function main()
    local registered, register_error = process.registry.register(service.SWEEPER_NAME)
    if not registered then error("register sweeper: " .. tostring(register_error)) end
    local events = assert(process.events())
    local ticker = time.ticker(tostring(service.SWEEP_INTERVAL_MS) .. "ms")
    while true do
        local selected = channel.select({ticker:channel():case_receive(), events:case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        else
            service.sweep()
        end
    end
end
return {main = main}

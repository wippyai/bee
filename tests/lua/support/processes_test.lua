local process = require("process")
local test = require("test")
local processes = require("processes")

local function exited(): string
    local events = assert(process.events())
    local runner = tostring(assert(process.spawn_monitored("bee.tests.support:exiting_runner", "bee:workers")))
    while true do
        local event = assert((events:receive()))
        if event.kind == process.event.EXIT and tostring(event.from) == runner then break end
    end
    process.unmonitor(runner)
    return runner
end

local function define_tests()
    test.describe("Process retirement", function()
        test.it("treats a runner that exited as vanished for monitor, cancel and send", function()
            local runner = exited()
            local monitored, monitor_error = process.monitor(runner)
            test.eq(monitored, nil)
            test.eq(processes.vanished(monitor_error), true)
            local cancelled, cancel_error = process.cancel(runner, "fixture complete")
            test.eq(cancelled, nil)
            test.eq(processes.vanished(cancel_error), true)
            local sent, send_error = process.send(runner, "bee.test.processes", {})
            test.eq(sent, nil)
            test.eq(processes.vanished(send_error), true)
        end)
        test.it("retires a runner that exited", function()
            local runner = exited()
            processes.cancel(runner)
            processes.join(runner)
        end)
    end)
end

local function exiting_runner(): integer
    return 0
end

return {run = test.run_cases(define_tests), exiting_runner = exiting_runner}

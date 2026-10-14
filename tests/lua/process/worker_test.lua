-- MIT. The shared worker loop: a pass at start and on every wake, a retry
-- after a pass that asked for one, and an end on cancellation.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")

local function next_value(listener: process.Listener, within: string): unknown
    local event = channel.select({listener:case_receive(), time.after(within):case_receive()})
    if not (event.ok and event.channel == listener) then return nil end
    return event.value:payload():data()
end

local function define_tests()
    test.describe("Worker loop", function()
        test.it("passes at start and on wake, retries a pass that asked for it, and ends when cancelled", function()
            local passes = assert(process.listen("bee.test.probe_pass", {message = true}))
            local done = assert(process.listen("bee.test.probe_done", {message = true}))
            local pid = assert(process.spawn("bee.tests.process:probe_worker", "bee:workers", tostring(process.pid())))
            test.eq(next_value(passes, "5s"), 1)
            local registered = nil
            for _ = 1, 50 do
                registered = process.registry.lookup("bee.test.probe_worker")
                if registered then break end
                time.sleep("20ms")
            end
            test.eq(tostring(registered), tostring(pid))
            process.send(tostring(pid), "bee.test.probe_wake", {})
            test.eq(next_value(passes, "5s"), 2)
            test.eq(next_value(passes, "5s"), 3)
            process.cancel(tostring(pid), "test done")
            test.eq(next_value(done, "5s"), 3)
            process.unlisten(passes)
            process.unlisten(done)
        end)
    end)
end
return test.run_cases(define_tests)

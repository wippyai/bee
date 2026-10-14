local test = require("test")
local process = require("process")
local completion = require("completion")
local function define_tests()
    test.describe("Fixture retirement", function()
        test.it("joins an exited fixture and cancels a live fixture without a snapshot race", function()
            local pid = tostring(assert(process.spawn("bee.tests.placement.native:retirement_fixture", "bee:workers")))
            completion.cancel(pid)
            completion.join(pid)
            completion.cancel(pid)
        end)
    end)
end
return {run = test.run_cases(define_tests), main = function() assert(process.events()):receive() end}

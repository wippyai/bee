-- MIT. Outlasts its own meta.timeout, which the run reports as the test's error.
local test = require("test")
local time = require("time")

local function define_tests()
    test.describe("timeout", function()
        test.it("sleeps past its limit", function()
            time.sleep("5s")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

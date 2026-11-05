-- MIT. Outlasts its own meta.timeout, which the run reports as the test's error.
local test = require("test")
local process = require("process")

local function define_tests()
    test.describe("timeout", function()
        test.it("outlasts its limit", function()
            local never = assert(process.listen("bee.test.runner.never", {message = true}))
            never:receive()
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

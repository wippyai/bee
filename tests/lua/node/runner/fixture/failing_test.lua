-- MIT. One case passes, one fails with a message the run reports and one is skipped.
local test = require("test")

local function define_tests()
    test.describe("results", function()
        test.it("passes", function()
            test.eq(1 + 1, 2)
        end)
        test.it("fails with its message", function()
            test.eq("expected", "actual")
        end)
        test.it_skip("is skipped", function() end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

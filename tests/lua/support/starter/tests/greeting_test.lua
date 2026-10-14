local test = require("test")
local greeting = require("greeting")
local function define_tests()
    test.describe("greeting", function()
        test.it("uses Bee for an empty name", function()
            test.eq(greeting.message("   "), "Hello, Bee")
        end)
        test.it("trims the requested name", function()
            test.eq(greeting.message("  Ada  "), "Hello, Ada")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

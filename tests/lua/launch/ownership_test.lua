-- MIT. Exactly one composition owns the retained workspace supervisor.
local test = require("test")
local ownership = require("ownership")

local function define_tests()
    test.describe("retained workspace ownership", function()
        test.it("the owner route spawns the retained supervisor only without a desktop bridge", function()
            test.is_true(ownership.spawn_retained(false))
        end)

        test.it("the desktop bridge owns the retained supervisor when configured", function()
            test.is_false(ownership.spawn_retained(true))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

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

        test.it("a desktop bridge exists only when the supervisor input configures desktop admission", function()
            test.is_false(ownership.desktop_bridge(nil))
            test.is_false(ownership.desktop_bridge({process = "bee.hive.supervisor:main", input = {{configured_nodes = {}}}}),
                "the supervisor service alone was taken for a desktop bridge")
            test.is_true(ownership.desktop_bridge({process = "bee.hive.supervisor:main",
                input = {{configured_nodes = {}, desktop = {execution = "e", expires_at = "t", allowed_nodes = {}, local_clients = true}}}}))
            test.is_false(ownership.desktop_bridge({input = "desktop"}))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

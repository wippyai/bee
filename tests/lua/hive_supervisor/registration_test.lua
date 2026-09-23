-- MIT. The supervisor publishes its eventual name whenever the node has a native
-- identity, with or without a desktop bridge, because the name is the only path a
-- local client has to discover it.
local test = require("test")
local registration = require("registration")

local function define_tests()
    test.describe("Hive supervisor name publication", function()
        test.it("publishes the eventual name when the node has a native identity and no desktop", function()
            local decision = registration.decide("owner-node", "bee.hive.supervisor/owner-node")
            test.is_true(decision.publish)
            test.eq(decision.name, "bee.hive.supervisor/owner-node")
            test.is_nil(decision.reason)
        end)

        test.it("stays local-only without a native node identity", function()
            local decision = registration.decide("", "bee.hive.supervisor/local")
            test.is_false(decision.publish)
            test.eq(decision.reason, "no native node identity")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

-- MIT. A retained-workspace boot failure reaches its owner with the Hive cause.
local test = require("test")
local startup_failure = require("startup_failure")

local function define_tests()
    test.describe("retained workspace startup failure", function()
        test.it("gets the local node identity from the owner process before Hive starts", function()
            test.eq(startup_failure.node_id("{node@bee.launch:owner|1}"), "node")
            test.is_nil(startup_failure.node_id("{bee.launch:owner|1}"))
        end)

        test.it("reports a local supervisor's bind failure instead of a readiness timeout", function()
            local reason = startup_failure.decode("{node@bee.hive.service:supervisor_host|1}",
                {version = 1, error = "failed to start membership service: listen tcp :44621: address already in use"}, "node")
            test.eq(reason, "Hive supervisor failed before retained workspace readiness: "
                .. "failed to start membership service: listen tcp :44621: address already in use")
        end)

        test.it("ignores malformed failures and unrelated processes", function()
            local sender = "{node@bee.hive.service:supervisor_host|1}"
            test.is_nil(startup_failure.decode(sender, {version = 2, error = "bind failed"}, "node"))
            test.is_nil(startup_failure.decode(sender, {version = 1, error = string.rep("x", 4097)}, "node"))
            test.is_nil(startup_failure.decode(sender, {version = 1, error = "bind failed"}, "other-node"))
            test.is_nil(startup_failure.decode("{node@bee.launch:owner|1}", {version = 1, error = "bind failed"}, "node"))
        end)

        test.it("keeps a forwarded boot error on one line", function()
            test.eq(startup_failure.decode("{node@bee.hive.service:supervisor_host|1}",
                {version = 1, error = "bind failed\nsecond line"}, "node"),
                "Hive supervisor failed before retained workspace readiness: bind failed second line")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

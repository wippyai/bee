-- MIT. A retained-workspace boot failure reaches its owner with the Hive cause.
local test = require("test")
local retained = require("retained")

local function define_tests()
    test.describe("retained workspace startup failure", function()
        test.it("gets the local node identity from the owner process before Hive starts", function()
            test.eq(retained.startup_node("{node@bee.launch:owner|1}"), "node")
            test.is_nil(retained.startup_node("{bee.launch:owner|1}"))
        end)

        test.it("reports a local supervisor's bind failure instead of a readiness timeout", function()
            local reason = retained.startup_failure("{node@bee.hive.service:supervisor_host|1}",
                {version = 1, error = "failed to start membership service: listen tcp :44621: address already in use"}, "node")
            test.eq(reason, "Hive supervisor failed before retained workspace readiness: "
                .. "failed to start membership service: listen tcp :44621: address already in use")
        end)

        test.it("ignores malformed failures and unrelated processes", function()
            local sender = "{node@bee.hive.service:supervisor_host|1}"
            test.is_nil(retained.startup_failure(sender, {version = 2, error = "bind failed"}, "node"))
            test.is_nil(retained.startup_failure(sender, {version = 1, error = string.rep("x", 4097)}, "node"))
            test.is_nil(retained.startup_failure(sender, {version = 1, error = "bind failed"}, "other-node"))
            test.is_nil(retained.startup_failure("{node@bee.launch:owner|1}", {version = 1, error = "bind failed"}, "node"))
        end)

        test.it("reads a failure retained before the owner registered its route", function()
            local detail = "workspace migration 9 (nested_bee_names_v1) checksum changed: expected abc, found unknown"
            test.eq(retained.stored_startup_failure(detail), "Hive supervisor failed before retained workspace readiness: " .. detail)
            test.is_nil(retained.stored_startup_failure(""))
            test.is_nil(retained.stored_startup_failure(string.rep("x", 4097)))
        end)

        test.it("preserves the full forwarded boot error for the owner log", function()
            test.eq(retained.startup_failure("{node@bee.hive.service:supervisor_host|1}",
                {version = 1, error = "bind failed\nsecond line"}, "node"),
                "Hive supervisor failed before retained workspace readiness: bind failed\nsecond line")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

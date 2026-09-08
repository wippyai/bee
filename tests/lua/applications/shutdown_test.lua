local test = require("test")
local shutdown = require("shutdown")

local function ids(...: string): {string}
    return {...}
end

local function define_tests()
    test.describe("Shutdown negotiation", function()
        test.it("waits for every app and records copied decisions once", function()
            local state = shutdown.start("request", ids("zeta", "alpha"))
            if not state then error("valid shutdown start was rejected") end
            test.is_false(shutdown.ready(state))
            test.is_false(shutdown.needs_confirmation(state))
            test.is_true(shutdown.record(state, "zeta", "Stop Zeta", "", false))
            test.is_false(shutdown.ready(state))
            test.is_false(shutdown.record(state, "zeta", "again", "", false))
            test.is_false(shutdown.record(state, "stale", "Stale", "", false))
            test.is_true(shutdown.record(state, "alpha", "Stop Alpha", "Unsaved work", false))
            test.is_true(shutdown.ready(state))
            test.is_true(shutdown.needs_confirmation(state))

            local result = shutdown.decisions(state)
            test.eq(#result, 2)
            test.eq(result[1].id, "alpha")
            test.eq(result[2].id, "zeta")
            result[1].message = "changed outside"
            result[1].force = true
            local copied = shutdown.decisions(state)
            test.eq(copied[1].message, "Unsaved work")
            test.is_false(copied[1].force)
        end)
        test.it("treats forced timeout as confirmation and removes exited apps", function()
            local state = shutdown.start("request", ids("responsive", "unresponsive", "gone"))
            if not state then error("valid shutdown start was rejected") end
            test.is_true(shutdown.record(state, "responsive", "Close", "", false))
            test.is_true(shutdown.record(state, "unresponsive", "Force stop", "", true))
            test.is_true(shutdown.needs_confirmation(state))
            test.is_false(shutdown.ready(state))
            shutdown.remove(state, "gone")
            test.is_false(shutdown.empty(state))
            shutdown.remove(state, "unresponsive")
            shutdown.remove(state, "responsive")
            test.is_true(shutdown.empty(state))
            test.is_true(shutdown.ready(state))
            test.is_false(shutdown.needs_confirmation(state))
        end)
        test.it("rejects malformed, duplicate, and oversized starts", function()
            test.is_nil(shutdown.start("", ids("one")))
            test.is_nil(shutdown.start("request", ids("one", "one")))
            test.is_nil(shutdown.start("request", ids("one", "two", string.rep("x", 81))))
            local too_many: {string} = {}
            for index = 1, 17 do too_many[index] = tostring(index) end
            test.is_nil(shutdown.start("request", too_many))
            local state = shutdown.start("request", ids("one", "two"))
            if not state then error("valid shutdown start was rejected") end
            test.eq(state.request_id, "request")
            test.is_false(shutdown.empty(state))
            test.is_false(shutdown.record(state, "unknown", "Unknown", "", false))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

-- MIT. An owner incarnation advances only when an owner starts.
local test = require("test")
local harness = require("harness")
local schema = require("schema")
local owner = require("owner")
local sql = require("sql")
local function define_tests()
    test.describe("Thread migration ledger", function()
        test.it("advances the owner incarnation only when an owner starts", function()
            local db = schema.open("bee.tests.threads:upgrade_test_db", "bee.threads.migrations")
            local first, first_error = owner.establish(db)
            if not first then error(tostring(first_error)) end
            local second = owner.establish(db)
            test.eq(second, first + 1)
            local tx = db:begin({isolation = sql.isolation.SERIALIZABLE})
            if not tx then error("begin") end
            test.eq(owner.current(tx), second)
            tx:rollback()
            db:release()
            local live = harness.open()
            local live_tx = live:begin({isolation = sql.isolation.SERIALIZABLE})
            if not live_tx then error("begin") end
            local running = owner.current(live_tx)
            live_tx:rollback()
            live:release()
            if not running then error("the owner service did not establish an incarnation at boot") end
            test.is_true(running >= 1)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

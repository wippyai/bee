local test = require("test")
local sql = require("sql")
local committed = require("committed")
type Object = {[string]: unknown}

local function define_tests()
    test.describe("Committed fixture completion", function()
        test.it("observes a completion committed between the state read and waiting", function()
            local db = assert(sql.get("bee:db"))
            local reads = 0
            local result = committed.await({"bee_test_completion"}, function(): Object
                reads = reads + 1
                local rows = assert(db:query("SELECT id FROM bee_test_completion"))
                if #rows > 0 then return {state = "complete"} end
                assert(db:execute("INSERT INTO bee_test_completion VALUES (1)"))
                return {state = "running"}
            end, function(value: Object): boolean return value.state == "complete" end, "2s", "fixture")
            assert(db:execute("DELETE FROM bee_test_completion"))
            db:release()
            test.eq(result.state, "complete")
            test.eq(reads, 2)
        end)
    end)
end

return test.run_cases(define_tests)

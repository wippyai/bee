-- MIT. Reading a volume does not let the reader watch it.
local test = require("test")
local funcs = require("funcs")
local security = require("security")

local function probe(policy: string): string
    local executor = assert(funcs.new():with_actor(assert(security.new_actor("bee.test.ioevents")))
        :with_scope(security.new_scope({assert(security.policy(policy)),
            assert(security.policy("bee.tests.ioevents:probe_call_policy"))})))
    return tostring(executor:call("bee.tests.ioevents:probe", "bee.tests.ioevents:watched"))
end

local function define_tests()
    test.describe("ioevents permission", function()
        test.it("refuses a watch the caller holds no ioevents.watch grant for", function()
            test.contains(probe("bee.tests.ioevents:read_policy"), "not permitted")
        end)
        test.it("admits a caller holding ioevents.watch without filesystem access", function()
            test.eq(probe("bee.tests.ioevents:watch_policy"), "watched")
        end)
    end)
end

return test.run_cases(define_tests)

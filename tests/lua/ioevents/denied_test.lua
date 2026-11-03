-- MIT. Watching a volume needs its filesystem and the ioevents.watch grant on it.
local test = require("test")
local funcs = require("funcs")
local security = require("security")

local function probe(...: string): string
    local policies = {assert(security.policy("bee.tests.ioevents:probe_call_policy"))}
    for _, policy in ipairs({...}) do policies[#policies + 1] = assert(security.policy(policy)) end
    local executor = assert(funcs.new():with_actor(assert(security.new_actor("bee.test.ioevents")))
        :with_scope(security.new_scope(policies)))
    return tostring(executor:call("bee.tests.ioevents:probe", "bee.tests.ioevents:watched"))
end

local function define_tests()
    test.describe("ioevents permission", function()
        test.it("refuses a watch the caller holds no ioevents.watch grant for", function()
            test.contains(probe("bee.tests.ioevents:read_policy"), "not permitted")
        end)
        test.it("refuses a caller without the filesystem to watch", function()
            test.contains(probe("bee.tests.ioevents:watch_policy"), "not allowed")
        end)
        test.it("admits a caller holding the filesystem and ioevents.watch on it", function()
            test.eq(probe("bee.tests.ioevents:read_policy", "bee.tests.ioevents:watch_policy"), "watched")
        end)
    end)
end

return test.run_cases(define_tests)

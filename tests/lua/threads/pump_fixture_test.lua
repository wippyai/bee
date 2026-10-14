-- SPDX-License-Identifier: MIT
local registry = require("registry")
local test = require("test")
local function define_tests()
    test.describe("Threads store fixture", function()
        test.it("keeps automatic forwarding disabled while suites claim the outbox", function()
            local entries = assert(registry.find({["meta.type"] = "bee.threads.owner"}))
            test.eq(#entries, 1)
            test.eq(entries[1].meta.pump, false)
        end)
    end)
end
return test.run_cases(define_tests)

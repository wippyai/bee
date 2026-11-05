-- SPDX-License-Identifier: MIT
local test = require("test")
local seams = require("seams")
local function define_tests()
    test.describe("Threads store fixture", function()
        test.it("keeps automatic forwarding disabled while suites claim the outbox", function()
            test.eq(seams["bee.threads.service.pump"](), false)
        end)
    end)
end
return test.run_cases(define_tests)

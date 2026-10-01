-- SPDX-License-Identifier: MIT
local test = require("test")
local budgets = require("budgets")
local descriptor = require("descriptor")
local function define_tests()
    test.describe("Profile budget accounting", function()
        test.it("rejects cost for every installed codec with an exact field reason", function()
            for _, provider in ipairs({"claude", "codex", "agy", "grok", "muse", "opencode"}) do
                local driver = assert(descriptor.load("bee.driver." .. provider .. ".descriptor:cli"))
                local reason = assert(budgets.accounting({turn = {cost_usd = 1}}, driver.capabilities and driver.capabilities.budgets, "headless", driver.codec))
                test.is_true(reason:find("budgets.turn.cost_usd", 1, true) ~= nil)
                test.is_true(reason:find(driver.codec, 1, true) ~= nil)
            end
        end)
        test.it("rejects window ceilings and admits only declared headless units", function()
            local coverage = {provider_steps = "agent_turn", tool_calls = true, tokens = false, wall_time_ms = true, cost_usd = false}
            test.not_nil(budgets.accounting({session = {wall_time_ms = 100}}, coverage, "window", "codec"))
            test.not_nil(budgets.accounting({session = {tokens = 1}}, coverage, "headless", "codec"))
            test.is_nil(budgets.accounting({turn = {tool_calls = 1}, session = {wall_time_ms = 100}}, coverage, "headless", "codec"))
        end)
    end)
end
return test.run_cases(define_tests)

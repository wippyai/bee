-- SPDX-License-Identifier: MIT
local test = require("test")
local planning = require("planning")
local counted = require("counted")
local fixtures = require("fixtures")
return test.run_cases(function()
    test.describe("Carrier schema measurement", function()
        test.it("reads the selected schema once per plan", function()
            local before = counted.reads()
            local ok, failure = pcall(function()
                local request = fixtures.request({thread_id = "schema-thread", action_id = "schema-action", attempt_id = "schema-attempt",
                    owner_id = "schema-owner", owner_incarnation = 1, binding_ref = "bee.drivers.claude.binding:binding", profile_id = "window",
                    brief = "schema test", policy_ref = "bee.driver.claude.security:launch_policy_claude_window", resources = {}, environment = {}})
                local reached = false
                local io: planning.IO = {
                    call = function(target: string, value: unknown): (unknown, string?) reached = true; return nil, "test stops before driver prepare" end,
                    send = function(target: string, topic: string, value: unknown) end,
                    self_pid = function(): string return "schema-test" end,
                    now_ms = function(): integer return 0 end,
                    key = function(): string return "schema-key" end,
                }
                local _, err = planning.plan(io, request)
                test.is_true(reached, tostring(err))
                test.eq(counted.reads() - before, 1, "one plan must not decode the same schema twice")
            end)
            if not ok then error(tostring(failure)) end
        end)
    end)
end)

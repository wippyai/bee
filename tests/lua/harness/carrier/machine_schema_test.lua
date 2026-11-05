-- SPDX-License-Identifier: MIT
local test = require("test")
local machine = require("machine")
local fixtures = require("fixtures")
local process = require("process")
local channel = require("channel")
return test.run_cases(function()
    test.describe("Carrier schema measurement", function()
        test.it("reads the selected schema once per plan", function()
            local reads_topic = assert(process.listen("bee.test.schema.read", {message = true}))
            assert(process.registry.register("bee.test.schema.reads"))
            local ok, failure = pcall(function()
                local request = fixtures.request({thread_id = "schema-thread", action_id = "schema-action", attempt_id = "schema-attempt",
                    owner_id = "schema-owner", owner_incarnation = 1, binding_ref = "bee.drivers.claude.binding:binding", profile_id = "window",
                    brief = "schema test", policy_ref = "bee.driver.claude.security:launch_policy_claude_window", resources = {}, environment = {}})
                local reached = false
                local io: machine.IO = {
                    call = function(target: string, value: unknown): (unknown, string?) reached = true; return nil, "test stops before driver prepare" end,
                    send = function(target: string, topic: string, value: unknown) end,
                    self_pid = function(): string return "schema-test" end,
                    now_ms = function(): integer return 0 end,
                    key = function(): string return "schema-key" end,
                }
                local _, err = machine.plan(io, request)
                test.is_true(reached, tostring(err))
                -- The seam reports each read synchronously from this process,
                -- so every read of the plan is queued once it returns.
                local reads = 0
                while channel.select({reads_topic:case_receive(), default = true}).channel == reads_topic do reads = reads + 1 end
                test.eq(reads, 1, "one plan must not decode the same schema twice")
            end)
            process.registry.unregister("bee.test.schema.reads")
            process.unlisten(reads_topic)
            if not ok then error(tostring(failure)) end
        end)
    end)
end)

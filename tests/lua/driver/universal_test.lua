-- MIT. The universal contract owns shared configure decoding and bounds.
local test = require("test")
local universal = require("universal")

local function define_tests()
    test.describe("Universal external driver", function()
        test.it("decodes configure input once before selecting its CLI renderer", function()
            local called = false
            local handle = universal.configure("bee.driver.claude.descriptor:cli", function(request)
                called = true
                test.eq(request.fixture, false)
                return {ok = true, delivery = {arguments = {}, files = {}}}
            end)
            local invalid = handle({fixture = "false"})
            test.eq(invalid.ok, false)
            test.is_false(called)
            local valid = handle({fixture = false})
            test.eq(valid.ok, true)
            test.is_true(called)
        end)
        test.it("selects the shared normalizer from the registry descriptor codec", function()
            local protocol = universal.protocol("bee.driver.opencode.descriptor:cli")
            test.eq(protocol.PROTOCOL_REVISION, "opencode-run-json-1")
            local handle = universal.normalize("bee.driver.opencode.descriptor:cli")
            local started = handle({index = 0, envelope = {type = "step_start", sessionID = "ses_universal"}})
            local reply = started :: {[string]: unknown}
            test.eq(reply.ok, true)
            test.is_true(type(reply.observations) == "table")
            local ended = handle({state = reply.state, index = 1, eof = true}) :: {[string]: unknown}
            local terminal = ended.terminal :: {[string]: unknown}
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.resume_ref, "ses_universal")
        end)

        test.it("refuses recursive flag rendering and oversized argv expansion", function()
            local recursive: {[string]: unknown} = {
                flags = {turn_budget = {field = "turn_budget", emit_default = true, argv = {{option = "turn_budget"}}}},
                options = {fields = {turn_budget = {type = "budget"}}},
            }
            local ok, argv, render_error = pcall(universal.render_argv, {{option = "turn_budget"}},
                {profile_id = "batch", brief = "work", turn_budget = 1}, recursive)
            test.is_true(ok)
            test.is_nil(argv)
            test.not_nil(render_error)

            local many: {string} = {}
            for index = 1, 129 do many[index] = "argument" end
            argv, render_error = universal.render_argv(many, {profile_id = "batch", brief = "work"}, {})
            test.is_nil(argv)
            test.not_nil(render_error)
        end)
    end)
end

return test.run_cases(define_tests)

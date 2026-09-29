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
    end)
end

return test.run_cases(define_tests)

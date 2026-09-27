local test = require("test")
local agents = require("agents")

local function receipt(): {[string]: unknown}
    return {
        thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-1",
        definition_ref = "host:agent", title = "Agent", brief = "Do the work",
        state = "starting", status = "starting", idempotency_key = "run-key",
        saved_profile_revision = 2, owner_component_revision = 3,
        receipt = {scope = "attempt", thread_id = "thread-1", action_id = "action-1",
            attempt_id = "attempt-1", state = "starting", idempotency_key = "run-key"},
    }
end

local function define_tests()
    test.describe("Agent run receipt boundary", function()
        test.it("decodes a bounded run and durable receipt", function()
            local decoded, err = agents.decode_run_receipt(receipt())
            if not decoded then error(tostring(err)) end
            test.eq(decoded.state, "starting")
            test.eq(decoded.status, "starting")
            test.eq(decoded.receipt.scope, "attempt")
            test.eq(decoded.owner_component_revision, 3)
        end)

        test.it("rejects invalid enums, revisions and receipt identity", function()
            local bad_state = receipt()
            bad_state.state = "complete"
            test.is_nil(agents.decode_run_receipt(bad_state))
            local bad_status = receipt()
            bad_status.status = 7
            test.is_nil(agents.decode_run_receipt(bad_status))
            local fractional = receipt()
            fractional.saved_profile_revision = 1.5
            test.is_nil(agents.decode_run_receipt(fractional))
            local string_revision = receipt()
            string_revision.owner_component_revision = "3"
            test.is_nil(agents.decode_run_receipt(string_revision))
            local bad_receipt = receipt()
            local evidence = bad_receipt.receipt :: {[string]: unknown}
            evidence.attempt_id = "another-attempt"
            test.is_nil(agents.decode_run_receipt(bad_receipt))
            local unknown = receipt()
            unknown.extra = true
            test.is_nil(agents.decode_run_receipt(unknown))
        end)
    end)
end

return test.run_cases(define_tests)

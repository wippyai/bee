local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local WORKSPACE = string.rep("a", 32)
local function define_tests()
    test.describe("Session close on placement exit", function()
        test.it("finishes a pending close on proven exit without an await observer", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {
                delivery = "hook", definition = "interactive-fixture",
                placement_methods = {reconcile = "bee.tests.sessions:interactive_exited"}}}))
            harness.value(journal:call("session_attach", {session = opened.session,
                attempt_id = "speed-exit", operation_key = harness.key()}))
            harness.value(journal:call("session_transition", {session = opened.session,
                state = "closing", operation_key = harness.key()}))
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:detach",
                {session = opened.session, attempt_id = "speed-exit", operation_key = harness.key()})
            if err then error(tostring(err)) end
            test.is_true(assert(bounds.object(raw)).ok)
            test.eq(harness.value(journal:call("session_describe", {session = opened.session})).state, "closed")
        end)
    end)
end
return test.run_cases(define_tests)

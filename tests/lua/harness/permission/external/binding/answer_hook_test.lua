local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local function define_tests()
    test.describe("External permission answer boundary", function()
        test.it("refuses a caller impersonating a stored session", function()
            local actor = assert(security.new_actor("different-session", {workspace_id = string.rep("a", 32)}))
            local raw, err = funcs.new():with_actor(actor):call("bee.harness.permission.external.binding:answer_hook", {
                session = "stored-session", definition = "bee.driver.muse.profiles:interactive", plan_digest = string.rep("a", 64),
                attempt_id = "attempt", thread_id = "thread", action_id = "action", binding_id = "binding",
                turn = "turn", claim = "claim", event_id = "event", payload = {}, transport = "hook_http"})
            assert(not err, tostring(err))
            local reply = assert(bounds.object(raw))
            test.eq(reply.ok, false)
            local failure = assert(bounds.object(reply.error))
            test.eq(failure.code, "PERMISSION_REFUSED")
            test.eq(failure.message, "hook is not an authenticated session boundary")
        end)
    end)
end
return test.run_cases(define_tests)

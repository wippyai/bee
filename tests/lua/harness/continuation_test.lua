-- MIT. Continuation comes from a successful owner receipt and native session.
local test = require("test")
local continuation = require("continuation")
local checkpoint = require("checkpoint")
local function define_tests()
    test.describe("Native harness continuation", function()
        test.it("uses the committed provider resume reference and refuses a mismatched or unfinished predecessor", function()
            local point = checkpoint.new({binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "batch", profile_digest = "profile-digest"}, 1)
            point.retained_session_ref = "session"
            point.output = "complete"
            point.terminal = {outcome = "succeeded", resume_ref = "native-session"}
            local stored: {[string]: unknown} = {attempt_id = "previous", action_id = "action", attempt_state = "ended", attempt_outcome = "succeeded", checkpoint = point}
            local attempt: {[string]: unknown} = {attempt_id = "previous", action_id = "action", owner_id = "alice", session_ref = "session", execution_state = "exited"}
            local placement_calls = 0
            local function call(target: string, input: unknown): (unknown, string?)
                if target == "bee.threads.carrier:checkpoint" then return {ok = true, value = stored}, nil end
                test.eq(target, "bee.placement.native:status")
                placement_calls = placement_calls + 1
                return {ok = true, value = {attempt = attempt}}, nil
            end
            local request: continuation.Request = {thread_id = "thread", action_id = "action", attempt_id = "next", owner_id = "alice", previous_attempt_id = "previous", session_ref = "session",
                binding_ref = "driver:binding", binding_digest = "binding-digest", profile_id = "batch", profile_digest = "profile-digest"}
            local resumed, err = continuation.resolve(call, request)
            test.is_nil(err)
            test.eq(resumed, "native-session")
            test.eq(placement_calls, 1)
            for _, state in ipairs({"prepared", "running"}) do
                stored.attempt_state = state
                test.is_nil(continuation.resolve(call, request))
            end
            stored.attempt_state = "ended"
            for _, outcome in ipairs({"failed", "cancelled", "uncertain"}) do
                stored.attempt_outcome = outcome
                test.is_nil(continuation.resolve(call, request))
            end
            stored.attempt_outcome = "succeeded"
            stored.action_id = "foreign"
            test.is_nil(continuation.resolve(call, request))
            stored.action_id = "action"
            point.binding_digest = "replacement-driver"
            test.is_nil(continuation.resolve(call, request))
            point.binding_digest = "binding-digest"
            point.retained_session_ref = "other-session"
            test.is_nil(continuation.resolve(call, request))
            point.retained_session_ref = "session"
            point.output = "open"
            test.eq(continuation.resolve(call, request), "native-session")
            test.eq(point.output, "open")
            point.output = "complete"
            point.terminal = {outcome = "succeeded"}
            test.is_nil(continuation.resolve(call, request))
            point.terminal = {outcome = "succeeded", resume_ref = "native-session"}
            attempt.owner_id = "bob"
            test.is_nil(continuation.resolve(call, request))
            attempt.owner_id = "alice"
            attempt.execution_state = "running"
            test.is_nil(continuation.resolve(call, request))
        end)
    end)
end
return test.run_cases(define_tests)

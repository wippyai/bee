-- MIT. Session discovery and addressing values, pure: one live session per
-- action under its newest carrier epoch, addresses resolved by action,
-- attempt or a thread holding exactly one session, and the listed view.
local test = require("test")
local sessions = require("sessions")
type Candidate = sessions.Candidate
local function candidate(action_id: string, attempt_id: string, thread_id: string, epoch: integer): Candidate
    return {binding_id = "binding-" .. attempt_id .. "-" .. tostring(epoch), subject = "subject", action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, carrier_epoch = epoch}
end
local function define_tests()
    test.describe("Gateway sessions", function()
        test.it("keeps one session per action under its newest carrier epoch in a stable order", function()
            local latest = sessions.latest({candidate("b", "b-1", "t2", 1), candidate("a", "a-1", "t1", 1), candidate("a", "a-2", "t1", 2), candidate("c", "c-1", "t1", 1)})
            test.eq(#latest, 3)
            test.eq(latest[1].action_id, "a")
            test.eq(latest[1].attempt_id, "a-2")
            test.eq(latest[2].action_id, "c")
            test.eq(latest[3].action_id, "b")
        end)
        test.it("resolves an action, an attempt or a thread that holds one session", function()
            local live = sessions.latest({candidate("a", "a-1", "t1", 1), candidate("c", "c-1", "t1", 1), candidate("b", "b-1", "t2", 1)})
            local by_action = sessions.resolve(live, "b")
            test.eq(by_action and by_action.attempt_id, "b-1")
            local by_attempt = sessions.resolve(live, "c-1")
            test.eq(by_attempt and by_attempt.action_id, "c")
            local by_thread = sessions.resolve(live, "t2")
            test.eq(by_thread and by_thread.action_id, "b")
            local ambiguous, code, message = sessions.resolve(live, "t1")
            test.is_nil(ambiguous)
            test.eq(code, "AMBIGUOUS")
            test.eq(message, "thread t1 holds 2 running sessions; name one by action: a, c")
            local missing, missing_code = sessions.resolve(live, "gone")
            test.is_nil(missing)
            test.eq(missing_code, "NOT_FOUND")
        end)
        test.it("lists the address, identities, title and whether the session is the caller", function()
            local view = sessions.view(candidate("a", "a-1", "t1", 1), "Fix the parser", "a")
            test.eq(view.session, "a")
            test.eq(view.action_id, "a")
            test.eq(view.attempt_id, "a-1")
            test.eq(view.thread_id, "t1")
            test.eq(view.title, "Fix the parser")
            test.eq(view.self, true)
            test.eq(sessions.view(candidate("b", "b-1", "t2", 1), "Review", "a").self, false)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

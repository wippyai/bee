-- MIT. Live carrier bindings, pure: one per action under its newest carrier epoch.
local test = require("test")
local sessions = require("sessions")
type Candidate = sessions.Candidate
type Object = {[string]: unknown}
local function candidate(action_id: string, attempt_id: string, thread_id: string, epoch: integer): Candidate
    return {binding_id = "binding-" .. attempt_id .. "-" .. tostring(epoch), subject = "subject", action_id = action_id, attempt_id = attempt_id, thread_id = thread_id, carrier_epoch = epoch}
end
local function define_tests()
    test.describe("Gateway sessions", function()
        test.it("keeps one session per action under its newest carrier epoch in stable action order", function()
            local latest = sessions.latest({candidate("b", "b-1", "t2", 1), candidate("a", "a-1", "t1", 1), candidate("a", "a-2", "t1", 2), candidate("c", "c-1", "t1", 1)})
            test.eq(#latest, 3)
            test.eq(latest[1].action_id, "a")
            test.eq(latest[1].attempt_id, "a-2")
            test.eq(latest[2].action_id, "b")
            test.eq(latest[3].action_id, "c")
        end)
        test.it("keeps the newest carrier binding of an action", function()
            local old = candidate("b", "attempt-old", "thread-b", 2)
            local current = candidate("b", "attempt-current", "thread-b", 3)
            local latest = sessions.latest({old, current})
            test.eq(#latest, 1)
            test.eq(latest[1].attempt_id, "attempt-current")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

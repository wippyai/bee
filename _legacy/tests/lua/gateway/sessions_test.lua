-- MIT. Workspace catalog rows come only from the public Sessions directory.
local test = require("test")
local sessions = require("sessions")
type Object = {[string]: unknown}
local function snapshot(ref: string, workspace: string): Object
    return {session = ref, workspace = workspace, revision = 1, incarnation = 1,
        title = "Claude", provider = "claude", lifecycle = "active", activity = "idle",
        execution = {state = "absent", evidence_at = "2026-09-30T00:00:00.000Z", stale = false},
        queue_count = 0, effective_limits = {}, continuity = {mode = "fresh"}, actions = {}}
end
local function define_tests()
    test.describe("Gateway Sessions projection", function()
        test.it("lists durable idle sessions without a live carrier or process", function()
            local rows, err = sessions.project({items = {snapshot("bs:node:home:one", "home")}}, "home")
            test.eq(err, nil)
            test.eq(#rows, 1)
            test.eq(rows[1].session, "bs:node:home:one")
            test.eq(rows[1].label, "Claude")
        end)
        test.it("filters the public directory by workspace and rejects malformed snapshots", function()
            local rows = sessions.project({items = {snapshot("bs:node:home:one", "home"), snapshot("bs:node:away:two", "away")}}, "home")
            test.eq(#rows, 1)
            local malformed, err = sessions.project({items = {{session = "carrier"}}}, "home")
            test.eq(malformed, nil)
            test.eq(type(err), "string")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}

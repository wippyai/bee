-- MIT. An elapsed deadline does not erase already delivered process exits.
local test = require("test")
local process = require("process")
local exits = require("exits")
local function exit(pid: string): process.Event
    return {kind = process.event.EXIT, from = pid, result = {value = {pid = pid}}, payload = function(): unknown return nil end}
end
local function define_tests()
    test.describe("Carrier exit collection", function()
        test.it("collects both queued exits when the scheduler selects an elapsed deadline", function()
            local queued: {process.Event} = {exit("old"), exit("replacement")}
            local outcomes = exits.collect({"old", "replacement"}, {}, function(poll: boolean): process.Event?
                if poll then return table.remove(queued, 1) end
                return nil
            end, "carriers")
            test.eq(assert(outcomes.old.value).pid, "old")
            test.eq(assert(outcomes.replacement.value).pid, "replacement")
        end)
        test.it("drains an exit delivered as the deadline is selected and keeps other results", function()
            local arrived = false
            local queued: {process.Event} = {}
            local saved: {[string]: exits.Outcome} = {}
            local outcome = exits.collect({"wanted"}, saved, function(poll: boolean): process.Event?
                if poll then return table.remove(queued, 1) end
                if not arrived then
                    arrived = true
                    queued = {exit("other"), exit("wanted")}
                end
                return nil
            end, "carrier")
            test.eq(assert(outcome.wanted.value).pid, "wanted")
            test.eq(assert(saved.other.value).pid, "other")
        end)
        test.it("reports the exact supervised cause when a carrier exits before an approval barrier", function()
            local saved: {[string]: exits.Outcome} = {}
            local event: process.Event = {kind = process.event.EXIT, from = "carrier", result = {error = "fixture response window elapsed"}, payload = function(): unknown return nil end}
            local ok, cause = pcall(function()
                exits.paused("carrier", "approval_created", saved, function(poll: boolean): unknown if poll then return nil end; return event end)
            end)
            test.is_false(ok)
            test.is_true(tostring(cause):find("fixture response window elapsed", 1, true) ~= nil)
            test.eq(saved.carrier.error, "fixture response window elapsed")
        end)
        test.it("observes a queued approval barrier when EXIT was selected first", function()
            local saved: {[string]: exits.Outcome} = {}
            local ended = false
            exits.paused("carrier", "approval_created", saved, function(poll: boolean): unknown
                if poll then
                    if ended then return {kind = "pause", from = "carrier", step = "approval_created"} end
                    return nil
                end
                ended = true
                return {kind = process.event.EXIT, from = "carrier", result = {error = "crash after approval_created"}}
            end)
            test.eq(saved.carrier.error, "crash after approval_created")
        end)
        test.it("reports cancellation while awaiting an approval barrier", function()
            local ok, cause = pcall(function()
                exits.paused("carrier", "approval_created", {}, function(poll: boolean): unknown
                    if poll then return nil end
                    return {kind = process.event.CANCEL}
                end)
            end)
            test.is_false(ok)
            test.is_true(tostring(cause):find("process observation cancelled", 1, true) ~= nil)
        end)
        test.it("reports the unchanged deadline when an awaited exit is absent", function()
            local ok, cause = pcall(function()
                exits.collect({"missing"}, {}, function(_poll: boolean): process.Event? return nil end, "carrier")
            end)
            test.is_false(ok)
            test.is_true(tostring(cause):find("carrier did not finish", 1, true) ~= nil)
        end)
    end)
end
return {run = test.run_cases(define_tests)}

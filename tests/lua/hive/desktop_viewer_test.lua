-- MIT. The remote view process answers its parent with exactly one failed
-- state when its arguments are invalid or no owner supervisor answers for the
-- node, and never attaches anything.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local protocol = require("protocol")
type Channel = channel.Channel
local WORKSPACE = string.rep("b", 32)
local function state(states: Channel<process.Message>, viewer: string): {[string]: unknown}
    local deadline = time.after("15s")
    local found: {[string]: unknown}? = nil
    while not found do
        local selected = channel.select({states:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("the remote view reported no state") end
        local message = selected.value
        if tostring(message:from()) == viewer then found = message:payload():data() :: {[string]: unknown} end
    end
    return found
end
local function define_tests()
    test.describe("Remote view process", function()
        test.it("fails without attaching for invalid arguments or an absent owner supervisor", function()
            local states = assert(process.listen(protocol.VIEW_STATE, {message = true}))
            local self = tostring(process.pid())
            local invalid = tostring(assert(process.spawn_monitored(protocol.VIEWER, protocol.CLIENT_HOST, self, "forge", "not-a-workspace", "control", 80, 24)))
            local refused = state(states, invalid)
            test.eq(refused.state, "failed")
            test.eq(refused.code, "INVALID_ARGUMENT")
            local absent = tostring(assert(process.spawn_monitored(protocol.VIEWER, protocol.CLIENT_HOST, self, "no-such-node", WORKSPACE, "observe", 80, 24)))
            local unavailable = state(states, absent)
            test.eq(unavailable.state, "failed")
            test.eq(unavailable.code, "UNAVAILABLE")
            process.unlisten(states)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

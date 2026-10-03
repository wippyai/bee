-- MIT. The remote view process answers its parent with exactly one failed
-- state when its arguments are invalid or no owner supervisor answers for the
-- node, and never attaches anything.
local test = require("test")
local bounds = require("bounds")
local process = require("process")
local channel = require("channel")
local time = require("time")
local protocol = require("protocol")
local registry = require("registry")
local decode = require("decode")
type Channel = channel.Channel
local WORKSPACE = string.rep("b", 32)
local function state(states: Channel<process.Message>, viewer: string): {[string]: unknown}
    local deadline = time.after("15s")
    local found: {[string]: unknown}? = nil
    while not found do
        local selected = channel.select({states:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("the remote view reported no state") end
        local message = selected.value
        if tostring(message:from()) == viewer then found = assert(bounds.object(message:payload():data())) end
    end
    return found
end
local function define_tests()
    test.describe("Remote view process", function()
        test.it("delivers an attached frame and exits cleanly after its parent closes it", function()
            local original = assert(registry.get(protocol.VIEWER))
            local changed = assert(registry.get(protocol.VIEWER))
            local data = assert(bounds.object(changed.data))
            local imports = assert(bounds.object(data.imports))
            imports.remote = "bee.hive:viewer_fixture"
            imports.display = "bee.hive:viewer_display_fixture"
            local changes = registry.snapshot():changes()
            changes:update(changed)
            assert(changes:apply())
            local states = assert(process.listen(protocol.VIEW_STATE, {message = true}))
            local frames = assert(process.listen(protocol.VIEW_FRAME, {message = true}))
            local events = assert(process.events())
            local viewer = tostring(assert(process.spawn_monitored(protocol.VIEWER, protocol.CLIENT_HOST,
                tostring(process.pid()), "forge", WORKSPACE, "observe", "attached-view", 80, 24)))
            local ok, failure = pcall(function()
                test.eq(state(states, viewer).state, "attached")
                local selected = channel.select({frames:case_receive(), events:case_receive()})
                if selected.channel == events then error("viewer exited before frame: " .. tostring(decode.exit_error(selected.value.result))) end
                local frame = assert(bounds.object(selected.value:payload():data()))
                local rows = assert(bounds.array(frame.rows, 24))
                test.eq(rows[1], "remote frame")
                assert(process.send(viewer, protocol.VIEW_CLOSE, {version = 1}))
                while true do
                    local event = assert((events:receive()))
                    if event.kind == process.event.EXIT and tostring(event.from) == viewer then
                        test.is_nil(decode.exit_error(event.result))
                        break
                    end
                end
            end)
            local restore = registry.snapshot():changes()
            restore:update(original)
            assert(restore:apply())
            process.unlisten(states)
            process.unlisten(frames)
            if not ok then process.terminate(viewer); error(tostring(failure)) end
        end)
        test.it("fails without attaching for invalid arguments or an absent owner supervisor", function()
            local states = assert(process.listen(protocol.VIEW_STATE, {message = true}))
            local self = tostring(process.pid())
            local invalid = tostring(assert(process.spawn_monitored(protocol.VIEWER, protocol.CLIENT_HOST, self, "forge", "not-a-workspace", "control", "invalid-view", 80, 24)))
            local refused = state(states, invalid)
            test.eq(refused.state, "failed")
            test.eq(refused.code, "INVALID_ARGUMENT")
            local absent = tostring(assert(process.spawn_monitored(protocol.VIEWER, protocol.CLIENT_HOST, self, "no-such-node", WORKSPACE, "observe", "absent-view", 80, 24)))
            local unavailable = state(states, absent)
            test.eq(unavailable.state, "failed")
            test.eq(unavailable.code, "UNAVAILABLE")
            process.unlisten(states)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

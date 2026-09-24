-- MIT. A retained display's switch request reaches the desktop bridge naming
-- the display it came from, and the bridge's answer reaches that display.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local desktops = require("desktops")
local desktop_lifecycle = require("desktop_lifecycle")
type Channel = channel.Channel
local WORKSPACE = "0123456789abcdef0123456789abcdef"
local DESKTOP = "fedcba9876543210fedcba9876543210"
local TARGET = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local function next_message(messages: Channel<process.Message>, what: string): process.Message
    local selected = channel.select({messages:case_receive(), time.after("3s"):case_receive()})
    if not selected.ok or selected.channel ~= messages then error("missing " .. what) end
    return selected.value
end
local function quiet(messages: Channel<process.Message>, what: string)
    local selected = channel.select({messages:case_receive(), time.after("200ms"):case_receive()})
    if selected.channel == messages then error("unexpected " .. what) end
end
local function define_tests()
    test.describe("Retained display switch routing", function()
        test.it("forwards a display's own switch request and returns the answer to it", function()
            local self = tostring(process.pid())
            local requests = assert(process.listen("bee.retained.switch", {message = true}))
            local relayed = assert(process.listen("bee.test.switch.relayed", {message = true}))
            local display = tostring(assert(process.spawn("bee.launch:switch_relay", "bee:workers", self)))
            local state = desktop_lifecycle.new(self, "host", "route", WORKSPACE, DESKTOP, desktops.new())
            local resource = {pid = display, database = "bee:client_db"} :: desktops.Desktop
            desktop_lifecycle.adopt(state, DESKTOP, resource, "connection-1")
            local handled = desktop_lifecycle.switch(state, display, {version = 1, workspace_id = WORKSPACE, desktop_id = DESKTOP,
                request_id = "switch-1", target_workspace_id = TARGET})
            test.is_true(handled)
            local forwarded = next_message(requests, "forwarded switch"):payload():data() :: {[string]: unknown}
            test.eq(forwarded.desktop_id, DESKTOP)
            test.eq(forwarded.workspace_id, WORKSPACE)
            test.eq(forwarded.target_workspace_id, TARGET)
            test.eq(forwarded.request_id, "switch-1")
            -- A display cannot ask for another display, and a stranger is not a display.
            desktop_lifecycle.switch(state, display, {version = 1, workspace_id = WORKSPACE, desktop_id = TARGET,
                request_id = "switch-2", target_workspace_id = TARGET})
            quiet(requests, "a switch for another display")
            test.is_false(desktop_lifecycle.switch(state, self, {version = 1, workspace_id = WORKSPACE, desktop_id = DESKTOP,
                request_id = "switch-3", target_workspace_id = TARGET}))
            desktop_lifecycle.switched(state, {version = 1, workspace_id = WORKSPACE, desktop_id = DESKTOP,
                request_id = "switch-1", error_code = "", error = ""})
            local answer = next_message(relayed, "relayed answer"):payload():data() :: {[string]: unknown}
            test.eq(answer.request_id, "switch-1")
            test.eq(answer.error_code, "")
            process.terminate(display)
            process.unlisten(requests); process.unlisten(relayed)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

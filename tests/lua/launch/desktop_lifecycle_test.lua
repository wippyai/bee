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
            local resource = {pid = display, database = "bee.env:client_db"} :: desktops.Desktop
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
    test.describe("Retained replacement readiness", function()
        test.it("waits for the matching host render result when the client presents first", function()
            local self = tostring(process.pid())
            local notices = assert(process.listen("bee.retained.replaced", {message = true}))
            local display = tostring(assert(process.spawn("bee.launch:switch_relay", "bee:workers", self)))
            local state = desktop_lifecycle.new(self, "host", "route", WORKSPACE, DESKTOP, desktops.new())
            desktop_lifecycle.adopt(state, DESKTOP,
                {pid = display, database = "bee.env:client_db"} :: desktops.Desktop, "connection-1")
            local child = state.children[DESKTOP]
            child.phase, child.pending, child.ready, child.restarts = "render", "render-1", false, 1
            test.is_true(desktop_lifecycle.receive(state, "presented", display, {version = 1,
                workspace_id = WORKSPACE, display_id = DESKTOP, connection_id = "connection-2",
                renderer = "presenter", generation = "generation-2"}))
            quiet(notices, "replacement readiness before host render")
            test.is_true(desktop_lifecycle.receive(state, "result", "route", {version = 1,
                workspace_id = WORKSPACE, request_id = "render-1", op = "render", recipient = display,
                connection_id = "connection-2", error_code = "", error = ""}))
            local notice = next_message(notices, "replacement readiness"):payload():data() :: {[string]: unknown}
            test.eq(notice.display_id, DESKTOP)
            test.eq(notice.pid, display)
            test.eq(notice.schema, 1)
            process.terminate(display)
            process.unlisten(notices)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

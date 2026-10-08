-- MIT. Hub application installation through the Library viewport.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local funcs = require("funcs")
local security = require("security")
local application = require("application")
local harness = require("harness")
local bounds = require("bounds")
local env = require("env")
local client = require("client")
local system = require("system")
local uuid = require("uuid")

type Window = {view: tty.Viewport, pid: string, events: Channel<process.Event>, workspace: string}
local function screen(view: tty.Viewport): string
    local shown = view:snapshot()
    return shown and (table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")) or ""
end
local function await(view: tty.Viewport, needle: string)
    local updates = assert(view:updates())
    local deadline = time.after("60s")
    while not screen(view):find(needle, 1, true) do
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("missing " .. needle .. " in:\n" .. screen(view)) end
    end
end
local function key(view: tty.Viewport, letter: string, kind: string?)
    assert(view:send({type = "key", key = letter, key_type = kind or "runes", action = "press"}))
end
local function open(): Window
    local added = assert(client.call(assert(system.node.id()), "workspace_add",
        {path = assert(env.get("bee.env:machine_home")) .. "/hub-ui-" .. uuid.v7()}))
    local workspace = assert(bounds.id(added.workspace))
    local view = assert(tty.viewport({width = 160, height = 45}))
    local definition = assert(application.definition("bee.apps.library:app"))
    local actor = assert(application.actor(workspace, "library-ui", definition, 1))
    local events = assert(process.events())
    local pid = assert(process.with_options({terminal = assert(view:grant())}):with_context({["bee.workspace_id"] = workspace})
        :with_actor(actor):with_scope(assert(application.scope(definition, workspace))):spawn_monitored(
        "bee.apps.library:app", "bee:workers", {workspace = {id = workspace}}))
    return {view = view, pid = tostring(pid), events = events, workspace = workspace}
end
local function close(window: Window)
    assert(process.cancel(window.pid, "Hub UI test complete"))
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({window.events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == window.events, "Library does not exit")
        if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == window.pid then break end
    end
    window.view:close()
end
local function details(window: Window)
    await(window.view, "LIBRARY")
    key(window.view, "", "tab")
    await(window.view, "Shared")
    key(window.view, "h")
    key(window.view, "/")
    await(window.view, "Type to edit")
    key(window.view, "progress")
    key(window.view, "", "enter")
    await(window.view, "Progress")
    key(window.view, "", "enter")
    await(window.view, "fixture README unavailable")
    key(window.view, "i")
    await(window.view, "Action install")
end
local function inbox(workspace: string): {unknown}
    local actor = assert(application.actor(workspace, "hub-ui-inbox", assert(application.definition("bee.approvals.inbox.app:app")), 1))
    local raw, problem = funcs.new():with_actor(actor):call("bee.approvals.binding:feed_snapshot", {workspace_id = workspace})
    return assert(bounds.array(harness.value(harness.reply(raw, problem)).items, 64))
end
local function define_tests()
    test.describe("Library Hub key flow", function()
        test.it("reviews a measured application and requests exactly one approval after confirmation", function()
            local window = open()
            local ok, failure = pcall(function()
                details(window)
                key(window.view, "e")
                await(window.view, "app.progress:title [string]")
                await(window.view, "Default: Progress")
                key(window.view, "", "enter")
                await(window.view, "Edit app.progress:title")
                for _ = 1, 8 do key(window.view, "", "backspace") end
                key(window.view, "Team progress")
                key(window.view, "", "enter")
                await(window.view, "Field saved")
                key(window.view, "p")
                key(window.view, "t")
                await(window.view, "Verdict ready")
                await(window.view, "pending migrations 2")
                test.eq(#inbox(window.workspace), 0)
                key(window.view, "", "enter")
                await(window.view, "Waiting for your approval")
                await(window.view, "Approval waits in Needs you")
                local items = inbox(window.workspace)
                test.eq(#items, 1)
                local item = assert(bounds.object(assert(bounds.object(items[1])).value))
                test.eq(item.state, "pending")
                local proposal = assert(bounds.object(item.proposal))
                local payload = assert(bounds.object(proposal.payload))
                test.eq(#assert(bounds.array(payload.migrations, 8)), 2)
                harness.answer(window.workspace, item.approval_id, "denied")
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
        test.it("shows a failed plan in the status line and Technical", function()
            local window = open()
            local ok, failure = pcall(function()
                details(window)
                key(window.view, "", "down")
                await(window.view, "Version 9.0.0")
                key(window.view, "p")
                await(window.view, "BLOCKED:")
                await(window.view, "Changes could not be read")
                local shown = assert(window.view:snapshot())
                test.is_true(shown.rows[#shown.rows]:find("BLOCKED:", 1, true) ~= nil)
                key(window.view, "t")
                await(window.view, "Last result: BLOCKED:")
                test.eq(#inbox(window.workspace), 0)
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)

-- MIT. The Modules app routes terminal input through the shared frame: the
-- frame delivers shortcut letters in lowercase, k opens the keyword filter on
-- the catalog phase only, and More and Help overlay the app's own screen.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local uuid = require("uuid")

local WORKSPACE = string.rep("d", 32)

type Window = {view: tty.Viewport, pid: string, events: Channel<process.Event>}

local function screen(view: tty.Viewport): string
    local shown = view:snapshot()
    return shown and (table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")) or ""
end

local function await(view: tty.Viewport, needle: string, present: boolean?)
    local expected = present ~= false
    local deadline = time.after("10s")
    while true do
        local found = screen(view):find(needle, 1, true) ~= nil
        if found == expected then return end
        local poll = time.after("50ms")
        local selected = channel.select({poll:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then
            error((expected and "missing " or "unexpected ") .. needle .. " in:\n" .. screen(view))
        end
    end
end

local function key(view: tty.Viewport, letter: string, key_type: string?)
    assert(view:send({type = "key", key = letter, key_type = key_type or "runes", action = "press"}))
end

local function open(width: integer, height: integer): Window
    local view = assert(tty.viewport({width = width, height = height}))
    local grant = assert(view:grant())
    local events = assert(process.events())
    local self = tostring(process.pid())
    local instance_id = "modules-" .. uuid.v7()
    local pid, spawn_error = process.with_options({terminal = grant}):spawn_monitored("bee.hub.modules:app", "bee:workers", {version = 1,
        broker_pid = self, workspace_pid = self, workspace_id = WORKSPACE, instance_id = instance_id, view_id = instance_id,
        definition_id = "bee.hub.modules:app", execution_generation = 1, definition_revision = "1", registry_revision = "1",
        launch_token = uuid.v7(), resume_schema = "", resume_state = "", arguments = {}})
    if not pid then error("modules spawn failed: " .. tostring(spawn_error)) end
    return {view = view, pid = tostring(pid), events = events}
end

local function close(window: Window)
    assert(process.cancel(window.pid, "modules routing test complete"))
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({window.events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == window.events, "the Modules app did not exit after cancellation")
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == window.pid then break end
    end
    window.view:close()
end

local function define_tests()
    test.describe("Modules frame routing", function()
        test.it("opens the keyword filter with k on the catalog and keeps k as a move elsewhere", function()
            local window = open(120, 36)
            local ok, failure = pcall(function()
                await(window.view, "MODULES  CATALOG")
                key(window.view, "k")
                await(window.view, "Filter by keyword")
                key(window.view, "", "esc")
                await(window.view, "Filter by keyword", false)
                key(window.view, "K")
                await(window.view, "Filter by keyword")
                key(window.view, "", "esc")
                await(window.view, "Filter by keyword", false)
                key(window.view, "o")
                await(window.view, "MODULES  OPERATIONS")
                key(window.view, "k")
                time.sleep("200ms")
                local shown = screen(window.view)
                test.is_nil((shown:find("Filter by keyword", 1, true)))
                test.is_true(shown:find("MODULES  OPERATIONS", 1, true) ~= nil)
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
        test.it("overlays shared Help and More and returns to the app on Esc", function()
            local window = open(40, 16)
            local ok, failure = pcall(function()
                await(window.view, "MODULES  CATALOG")
                await(window.view, "? help")
                key(window.view, "?")
                await(window.view, "HELP")
                key(window.view, "", "esc")
                await(window.view, "MODULES  CATALOG")
                await(window.view, "F10 More")
                key(window.view, "", "f10")
                await(window.view, "MORE ACTIONS")
                key(window.view, "", "esc")
                await(window.view, "MODULES  CATALOG")
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)

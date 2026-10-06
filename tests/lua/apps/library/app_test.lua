-- MIT. The Library app routes terminal input through the shared frame: the
-- frame delivers shortcut letters in lowercase, k opens the keyword filter on
-- the Shared tab only, and More and Help overlay the app's own screen.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")

type Window = {view: tty.Viewport, pid: string, events: Channel<process.Event>}

local function screen(view: tty.Viewport): string
    local shown = view:snapshot()
    return shown and (table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")) or ""
end

-- await follows the viewport's presented screens until needle is shown, or
-- gone when present is false.
local function await(view: tty.Viewport, needle: string, present: boolean?)
    local expected = present ~= false
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local found = screen(view):find(needle, 1, true) ~= nil
        if found == expected then return end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
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
    local pid, spawn_error = process.with_options({terminal = grant}):spawn_monitored("bee.apps.library:app", "bee:workers", {workspace = {id = "workspace-test"}})
    if not pid then error("library spawn failed: " .. tostring(spawn_error)) end
    return {view = view, pid = tostring(pid), events = events}
end

local function close(window: Window)
    assert(process.cancel(window.pid, "library routing test complete"))
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({window.events:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == window.events, "the Library app did not exit after cancellation")
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == window.pid then break end
    end
    window.view:close()
end

local function define_tests()
    test.describe("Library frame routing", function()
        test.it("opens the keyword filter with k on Shared and keeps k as a move elsewhere", function()
            local window = open(120, 36)
            local ok, failure = pcall(function()
                await(window.view, "LIBRARY")
                key(window.view, "k")
                test.is_nil((screen(window.view):find("Filter by keyword", 1, true)))
                key(window.view, "", "tab")
                await(window.view, "Developer packages")
                key(window.view, "k")
                await(window.view, "Filter by keyword")
                key(window.view, "", "esc")
                await(window.view, "Filter by keyword", false)
                key(window.view, "K")
                await(window.view, "Filter by keyword")
                key(window.view, "", "esc")
                await(window.view, "Filter by keyword", false)
                key(window.view, "", "tab")
                await(window.view, "No history yet")
                key(window.view, "k")
                key(window.view, "/")
                await(window.view, "Type to edit")
                test.is_nil((screen(window.view):find("Filter by keyword", 1, true)))
                key(window.view, "", "esc")
                await(window.view, "Type to edit", false)
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
        test.it("overlays shared Help and More and returns to the app on Esc", function()
            local window = open(28, 16)
            local ok, failure = pcall(function()
                await(window.view, "LIBRARY")
                await(window.view, "? help")
                key(window.view, "?")
                await(window.view, "HELP")
                key(window.view, "", "esc")
                await(window.view, "LIBRARY")
                await(window.view, "F10 More")
                key(window.view, "", "f10")
                await(window.view, "MORE ACTIONS")
                key(window.view, "", "esc")
                await(window.view, "LIBRARY")
            end)
            close(window)
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)

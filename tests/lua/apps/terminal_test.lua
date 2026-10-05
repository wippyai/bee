-- MIT. Terminal opens a shell in its desktop's workspace folder, takes the
-- keys a display sends and exits with its shell when the node closes it.
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local time = require("time")
local tty = require("tty")
local client = require("client")

local TERMINAL = "bee.apps.terminal:app"

local function call(op: string, args: {[string]: unknown}): {[string]: unknown}
    local value, err = client.call(assert(system.node.id()), op, args)
    if not value then error(op .. ": " .. tostring(err)) end
    return value
end

local function screen(view: tty.Viewport): string
    local snapshot = view:snapshot()
    if not snapshot then return "" end
    return (table.concat(snapshot.rows, "\n"):gsub("\27%[[0-9;]*m", ""))
end

local function shows(view: tty.Viewport, text: string): boolean
    local updates = assert(view:updates())
    local deadline = time.after("5s")
    while true do
        if screen(view):find(text, 1, true) then return true end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then return false end
    end
end

local function type_line(view: tty.Viewport, text: string)
    for character in text:gmatch(".") do
        if character == " " then assert(view:send({type = "key", key = " ", key_type = "space", action = "press"}))
        else assert(view:send({type = "key", key = character, key_type = "runes", action = "press"})) end
    end
    assert(view:send({type = "key", key = "", key_type = "enter", action = "press"}))
end

local function define_tests()
    test.describe("Terminal", function()
        test.it("runs a shell in the desktop's workspace folder and stops with it", function()
            local state = assert(client.state(call("watch", {})))
            local folder = ""
            for _, workspace in ipairs(state.workspaces) do
                for _, desktop in ipairs(state.desktops) do
                    if desktop.id == state.desktop and desktop.workspace == workspace.id then folder = workspace.path end
                end
            end
            test.neq(folder, "")
            local opened = call("open", {app = TERMINAL, desktop = state.desktop})
            local attached = call("attach", {id = opened.id})
            local view = assert(tty.attach(tostring(attached.ref)))
            type_line(view, "echo at-$PWD")
            if not shows(view, "at-" .. folder) then error("the shell runs elsewhere: screen was\n" .. screen(view)) end

            local events = assert(process.listen(client.EVENTS, {message = true}))
            call("close", {id = opened.id})
            local deadline = time.after("5s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("the terminal did not exit with its shell") end
                local event = client.event(selected.value:payload():data())
                if event and event.kind == "closed" and event.id == opened.id then break end
            end
            process.unlisten(events)
            view:close()
            call("leave", {})
        end)
    end)
end
return test.run_cases(define_tests)

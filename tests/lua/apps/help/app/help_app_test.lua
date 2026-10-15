-- SPDX-License-Identifier: MIT
local test = require("test")
local tty = require("tty")
local system = require("system")
local time = require("time")
local channel = require("channel")
local fs = require("fs")
local client = require("client")
local manuals = require("manuals")
type Snapshot = {width: integer, height: integer, rows: {string}}
local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function await(viewport: tty.Viewport, needle: string): Snapshot
    local updates = assert(viewport:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = viewport:snapshot()
        if snapshot and tty.text.plain(table.concat(snapshot.rows)):find(needle, 1, true) then return {width = snapshot.width, height = snapshot.height, rows = snapshot.rows} end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Help screen has no " .. needle)
    end
end
local function key(viewport: tty.Viewport, kind: string, value: string?)
    assert(viewport:send({type = "key", action = "press", key_type = kind, key = value or ""}))
end
local function capture(name: string, snapshot: Snapshot)
    test.eq(snapshot.width, 120)
    test.eq(snapshot.height, 40)
    local captures = assert(fs.get("bee.tests.apps.help.app:captures"))
    assert(captures:writefile(name .. ".txt", tty.text.plain(table.concat(snapshot.rows, "\n")) .. "\n"))
end
local function define_tests()
    test.describe("Help manuals application", function()
        test.it("browses searches scrolls and returns to the list after resize", function()
            local expected = tostring(#assert(manuals.load())) .. " manuals"
            local state = assert(client.state(call("watch", {})))
            local opened = call("open", {app = "bee.apps.help.app:app", desktop = state.desktop})
            local id = tostring(opened.id)
            local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local ok, failure = pcall(function()
                assert(viewport:resize(120, 40))
                await(viewport, "BEE KEYBOARD HELP")
                for _ = 1, 4 do key(viewport, "tab") end
                local listing = await(viewport, expected)
                capture("agent-manuals-120x40", listing)
                key(viewport, "runes", "/")
                key(viewport, "runes", "bearer_token_env_var")
                await(viewport, "External MCP clients")
                key(viewport, "enter")
                key(viewport, "enter")
                await(viewport, "AGENT MANUALS")
                capture("agent-manual-read-120x40", await(viewport, "HOW TO CONNECT"))
                assert(viewport:resize(40, 12))
                await(viewport, "AGENT MANUALS")
                key(viewport, "pgdown")
                await(viewport, "gateway_surface.access")
                key(viewport, "esc")
                await(viewport, "BEE KEYBOARD HELP")
                key(viewport, "esc")
                await(viewport, expected)
            end)
            call("close", {id = id})
            viewport:close()
            call("leave", {})
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)

-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local system = require("system")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local client = require("client")
local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function shows(view: tty.Viewport, width: integer, height: integer)
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.width == width and snapshot.height == height and #snapshot.rows == height
            and tty.text.plain(table.concat(snapshot.rows)):find("No external clients", 1, true) then
            for _, row in ipairs(snapshot.rows) do test.eq(tty.text.width(row), width) end
            return
        end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "MCP clients does not render after terminal input")
    end
end
local function define_tests()
    test.describe("MCP clients application", function()
        test.it("handles startup, keyboard, mouse and resize events from a real viewport", function()
            local state = assert(client.state(call("watch", {})))
            local opened = call("open", {app = "bee.gateway.app:app", desktop = state.desktop})
            local id = tostring(opened.id)
            local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local ok, failure = pcall(function()
                assert(viewport:resize(100, 24))
                shows(viewport, 100, 24)
                assert(viewport:send({type = "key", action = "press", key_type = "down", key = ""}))
                assert(viewport:send({type = "key", action = "press", key_type = "runes", key = "r"}))
                assert(viewport:resize(80, 20))
                shows(viewport, 80, 20)
                assert(viewport:send({type = "mouse", action = "press", button = "left", x = 2, y = 3}))
                assert(viewport:resize(48, 16))
                shows(viewport, 48, 16)
                assert(viewport:send({type = "key", action = "press", key_type = "up", key = ""}))
                assert(viewport:resize(120, 30))
                shows(viewport, 120, 30)
            end)
            call("close", {id = id})
            viewport:close()
            call("leave", {})
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)

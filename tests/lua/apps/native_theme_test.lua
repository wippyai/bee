-- MIT. Settings selects and stores Native through the node appearance path.
local test = require("test")
local process = require("process")
local system = require("system")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local client = require("client")
local appearance = require("appearance")
local settings = require("settings")

local function call(op: string, args: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), op, args))
end

local function shows(view: tty.Viewport, needle: string, width: integer?, height: integer?)
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and (not width or snapshot.width == width) and (not height or (snapshot.height == height and #snapshot.rows == height))
            and tty.text.plain(table.concat(snapshot.rows)):find(needle, 1, true) then return end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Settings does not show " .. needle)
    end
end

local function changed(inbox: channel.Channel, id: string)
    local deadline = time.after("10s")
    while true do
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Settings does not apply " .. id)
        local event = client.event(selected.value:payload():data())
        if event and event.kind == "appearance" and event.appearance and event.appearance.theme.id == id then return end
    end
end

local function define_tests()
    test.describe("Native Settings", function()
        test.it("lists Native, selects it from Settings, and persists the choice", function()
            local state = assert(client.state(call("watch", {})))
            local themes: {appearance.Theme} = {}
            local native_index = 0
            for _, item in ipairs(call("themes", {}).themes :: {unknown}) do
                local theme = assert(appearance.decode_theme(item))
                themes[#themes + 1] = theme
                if theme.title == "Native" then native_index = #themes end
            end
            test.is_true(native_index > 0, "Native is absent from Settings themes")
            local opened = call("open", {app = "bee.apps.settings:app", desktop = state.desktop})
            local id = tostring(opened.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local inbox = assert(process.listen(client.EVENTS, {message = true}))
            local ok, failure = pcall(function()
                shows(view, "✓ " .. state.appearance.theme.title)
                assert(view:send({type = "key", key = "", key_type = "home", action = "press"}))
                changed(inbox, themes[1].id)
                for index = 2, native_index do
                    assert(view:send({type = "key", key = "", key_type = "right", action = "press"}))
                    changed(inbox, themes[index].id)
                end
                shows(view, "✓ Native")
                test.eq(settings.get("theme"), themes[native_index].id)
                local selected = assert(client.state(call("list", {})))
                test.eq(selected.appearance.theme.id, themes[native_index].id)
                test.eq(selected.appearance.theme.text, "default")
                assert(view:resize(24, 5))
                shows(view, "‹", 24, 5)
                shows(view, "Native")
                local snapshot = assert(view:snapshot())
                local rows = table.concat(snapshot.rows)
                test.is_nil((rows:find("38;2;", 1, true)), rows)
                test.is_nil((rows:find("48;2;", 1, true)), rows)
            end)
            call("close", {id = id})
            call("appearance", {theme = state.appearance.theme.id})
            process.unlisten(inbox)
            view:close()
            call("leave", {})
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)

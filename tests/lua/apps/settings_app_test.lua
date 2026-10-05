-- MIT. The Settings app opens About from its tabs and shows the live Bee
-- packs it reads through the Hub facade with its own grants.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")

local function screen(view: tty.Viewport): string
    local shown = view:snapshot()
    return shown and (table.concat(shown.rows, "\n"):gsub("\27%[[0-9;]*m", "")) or ""
end

-- await follows the viewport's presented screens until one of needles shows.
local function await(view: tty.Viewport, needles: {string}): string
    local updates = assert(view:updates())
    local deadline = time.after("30s")
    while true do
        local shown = screen(view)
        for _, needle in ipairs(needles) do
            if shown:find(needle, 1, true) then return needle end
        end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then error("missing " .. table.concat(needles, " or ") .. " in:\n" .. shown) end
    end
end

local function define_tests()
    test.describe("Settings app", function()
        test.it("reads the live Bee packs when About opens", function()
            local view = assert(tty.viewport({width = 100, height = 30}))
            local grant = assert(view:grant())
            local events = assert(process.events())
            local pid = assert(process.with_options({terminal = grant}):spawn_monitored("bee.apps.settings:app", "bee:workers", {}))
            local ok, failure = pcall(function()
                await(view, {"BEE SETTINGS · DISPLAY"})
                -- Themes, Backgrounds, Tabs, Edit mode, then About.
                for _ = 1, 4 do assert(view:send({type = "key", key = "", key_type = "tab", action = "press"})) end
                await(view, {"BEE SETTINGS · ABOUT"})
                local outcome = await(view, {"INSTALLED", "Status    unavailable"})
                if outcome == "Status    unavailable" then
                    test.is_nil((screen(view):find("DENIED", 1, true)), screen(view))
                end
            end)
            assert(process.cancel(tostring(pid), "settings app test complete"))
            local deadline = time.after("10s")
            while true do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                assert(selected.ok and selected.channel == events, "the Settings app did not exit after cancellation")
                if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == tostring(pid) then break end
            end
            view:close()
            if not ok then error(tostring(failure)) end
        end)
    end)
end

return test.run_cases(define_tests)

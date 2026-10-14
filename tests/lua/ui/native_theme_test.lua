-- MIT. Native frames retain terminal colors and selection attributes.
local test = require("test")
local registry = require("registry")
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local render = require("render")
local settings_view = require("settings_view")

local function native(): appearance.Theme
    for _, entry in ipairs(registry.find({["meta.type"] = appearance.TYPE}) or {}) do
        local data = entry.data :: {[string]: unknown}
        if data.title == "Native" then
            local value: {[string]: unknown} = {id = entry.id}
            for key, item in pairs(data) do value[key] = item end
            return assert(appearance.decode_theme(value))
        end
    end
    error("Native is absent from the theme catalog")
end

local function no_rgb(rows: {string})
    local text = table.concat(rows, "\n")
    test.is_nil((text:find("38;2;", 1, true)))
    test.is_nil((text:find("48;2;", 1, true)))
end

local function reversed(rows: {string}): boolean
    for codes in table.concat(rows):gmatch("\27%[([0-9;]*)m") do
        for code in codes:gmatch("%d+") do if code == "7" then return true end end
    end
    return false
end

local function define_tests()
    test.describe("Native frames", function()
        test.it("discovers Native through theme metadata with terminal roles", function()
            local theme = native()
            test.eq(theme.ground, "default")
            test.eq(theme.surface, "default")
            test.eq(theme.text, "default")
            test.eq(theme.ok, "ansi:2")
            test.eq(theme.warn, "ansi:3")
            test.eq(theme.error, "ansi:1")
            test.is_nil(appearance.page(theme, false))
            test.is_nil(appearance.page(theme, true))
        end)

        test.it("paints desktop, named chrome, menus and app rows without RGB", function()
            local preferences: appearance.Preferences = {theme = native(), background = "dots", taskbar = "labels"}
            no_rgb(render.draw(model.new(80, 24), {}, {}, nil, nil, "", "Desktop", preferences, {}).rows)
            local painter = frame.new(36, 8, preferences)
            frame.header(painter, "App", "Muted")
            frame.row(painter, 3, "Selected", true, "row", 1, "one")
            frame.actions(painter, 7, {{kind = "save", label = "Save", enabled = true, primary = true}})
            local rows = frame.rows(painter)
            no_rgb(rows)
            test.is_true(reversed(rows))
            for _, name in ipairs({"", "amber", "cyan", "green", "rose", "violet"}) do
                local scene = model.add(model.new(80, 24), "one", "one", "App")
                scene.windows[1].accent = name
                local drawn = render.draw(scene, {"one"}, {one = {rows = rows}}, nil, nil, "", "Desktop", preferences,
                    {start = {selected = 1, offset = 0}})
                no_rgb(drawn.rows)
                test.is_true(reversed(drawn.rows))
            end
            local shown = settings_view.draw(80, 24, preferences, {preferences.theme}, "theme", 0)
            no_rgb(shown.rows)
            test.contains(tty.text.plain(table.concat(shown.rows)), "Native")
        end)

        test.it("clears dim and reverse attributes before ordinary text", function()
            local theme = native()
            local canvas = tty.canvas(12, 1)
            canvas:put(1, 1, appearance.style(theme.muted, theme.surface) .. "dim"
                .. appearance.style(theme.text, theme.surface) .. "normal", 12)
            local expected = tty.canvas(12, 1)
            expected:put(1, 1, "\27[2mdim\27[0mnormal", 12)
            test.eq(canvas:rows()[1], expected:rows()[1])
            canvas:put(1, 1, appearance.style(theme.text, theme.on_accent_background or theme.accent) .. "rev"
                .. appearance.style(theme.text, theme.surface) .. "normal", 12)
            expected:put(1, 1, "\27[7mrev\27[0mnormal", 12)
            test.eq(canvas:rows()[1], expected:rows()[1])
        end)
    end)
end

return test.run_cases(define_tests)

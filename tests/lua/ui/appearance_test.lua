-- MIT. A palette carries an id, a title and a terminal color for every role;
-- preferences carry a palette, a known background and a taskbar style.
-- Anything else is refused, and a missing value falls back to the defaults.
local test = require("test")
local appearance = require("appearance")

local function palette(): {[string]: unknown}
    local value: {[string]: unknown} = {id = "acme:night", title = "Night"}
    for _, role in ipairs(appearance.ROLES) do value[role] = "#102030" end
    return value
end

local function define_tests()
    test.describe("palettes", function()
        test.it("decodes a complete palette with optional roles", function()
            local value = palette()
            value.on_accent = "#ffffff"
            local decoded = appearance.decode_theme(value)
            test.not_nil(decoded)
            test.eq((decoded or appearance.default_theme()).pattern, "#102030")
            test.eq(appearance.selection_text(decoded or appearance.default_theme()), "#ffffff")
        end)

        test.it("refuses a palette missing a role or with a malformed color", function()
            local missing = palette()
            missing.pattern = nil
            test.is_nil(appearance.decode_theme(missing))
            local malformed = palette()
            malformed.text = "red"
            test.is_nil(appearance.decode_theme(malformed))
            local optional = palette()
            optional.on_accent = "white"
            test.is_nil(appearance.decode_theme(optional))
        end)
    end)

    test.describe("terminal colors", function()
        test.it("resolves terminal defaults and all sixteen ANSI colors", function()
            local value = palette()
            value.ground, value.surface, value.text = "default", "default", "default"
            value.muted = "default:dim"
            value.on_accent_background = "default:reverse"
            for index = 0, 15 do
                value.accent = "ansi:" .. tostring(index)
                local theme = assert(appearance.decode_theme(value))
                test.eq(theme.text, "default")
                test.eq(appearance.style(theme.text, theme.surface), "\27[22;27m\27[39m\27[49m")
                test.contains(appearance.style(theme.accent, theme.surface), "\27[" .. tostring(index < 8 and 30 + index or 90 + index - 8) .. "m")
                test.is_nil(appearance.page(theme, false))
                test.is_nil(appearance.page(theme, true))
            end
            value.accent = "ansi:16"
            test.is_nil(appearance.decode_theme(value))
        end)

        test.it("preserves terminal colors through intensity ramps and named accents", function()
            local value = palette()
            value.surface = "default"
            local theme = assert(appearance.decode_theme(value))
            local accent = appearance.instance_accent(theme, "cyan")
            test.eq(accent, "ansi:6")
            test.eq(appearance.mix("default", "ansi:2", 0.35), "ansi:2")
            test.eq(appearance.mix("default", "ansi:2", 0), "default")
        end)
    end)

    test.describe("preferences", function()
        test.it("decodes a palette, a known background and a taskbar style", function()
            local decoded = appearance.decode({theme = palette(), background = "grid", taskbar = "icons"})
            test.not_nil(decoded)
            test.eq((decoded or appearance.defaults()).background, "grid")
            test.is_nil(appearance.decode({theme = palette(), background = "lava", taskbar = "icons"}))
            test.is_nil(appearance.decode({theme = palette(), background = "grid", taskbar = "tiles"}))
        end)

        test.it("falls back to the defaults when a value carries none", function()
            test.eq(appearance.chosen(nil).background, appearance.defaults().background)
            test.eq(appearance.chosen({appearance = {theme = palette(), background = "dots", taskbar = "labels"}}).theme.id, "acme:night")
        end)
    end)

    test.describe("wallpaper", function()
        test.it("repeats a pattern across the width and leaves solid blank", function()
            test.contains(appearance.background_row("dots", 40, 2, 10), "·")
            test.eq(appearance.background_row("solid", 4, 1, 10), "    ")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}

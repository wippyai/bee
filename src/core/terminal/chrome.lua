local tty = require("tty")
local appearance = require("appearance")
local M = {}
function M.background(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences)
    local theme = appearance.theme(preferences.theme)
    local base = appearance.style(theme.text, theme.ground)
    local pattern = appearance.style(theme.pattern, theme.ground)
    canvas:clear(base .. " \27[0m")
    if preferences.background == "solid" then return end
    for y = 2, height do
        canvas:put(1, y, pattern .. appearance.background_row(preferences.background, width, y - 1, height - 1) .. "\27[0m", width)
    end
end
function M.welcome(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, starting: boolean)
    local theme = appearance.theme(preferences.theme)
    local lines: {string} = {
        "██████╗ ███████╗███████╗",
        "██╔══██╗██╔════╝██╔════╝",
        "██████╔╝█████╗  █████╗  ",
        "██╔══██╗██╔══╝  ██╔══╝  ",
        "██████╔╝███████╗███████╗",
        "╚═════╝ ╚══════╝╚══════╝"}
    if width < 32 or height < 12 then lines = {"BEE"} end
    if starting and height >= 5 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Starting your workspace..."
    end
    local top = math.floor(math.max(2, (height - #lines) / 2))
    if height < 3 then top = 1 end
    for index, text in ipairs(lines) do
        local y = top + index - 1
        if y < height or height < 3 then
            local x = math.floor(math.max(1, (width - tty.text.width(text)) / 2 + 1))
            local color = starting and theme.accent or theme.pattern
            canvas:put(x, y, appearance.style(color, theme.ground) .. text .. "\27[0m", math.floor(math.max(0, width - x + 1)))
        end
    end
end
function M.boot(width: integer, height: integer): {string}
    local canvas = tty.canvas(width, height)
    local preferences = appearance.defaults()
    M.background(canvas, width, height, preferences)
    M.welcome(canvas, width, height, preferences, true)
    return canvas:rows()
end
return M

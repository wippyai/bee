local tty = require("tty")
local appearance = require("appearance")
local M = {}
-- LOGO is the cell-native bee: folded wings and striped body, with no
-- terminal-dependent emoji width.
local LOGO: {string} = {
    "    ╭──╮ ╭──╮    ",
    "    ╰──╲ ╱──╯    ",
    " ╭──────┴─────╮  ",
    "◂│ ██  ██  •  │  ",
    " ╰────────────╯  ",
    "       ╲ ╲       "}

function M.background(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences): ()
    local theme = preferences.theme
    local base = appearance.style(theme.text, theme.ground)
    local pattern = appearance.style(theme.pattern, theme.ground)
    canvas:clear(base .. " \27[0m")
    if preferences.background == "solid" then return end
    for y = 2, height do
        canvas:put(1, y, pattern .. appearance.background_row(preferences.background, width, y - 1, height - 1) .. "\27[0m", width)
    end
end
function M.welcome(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, starting: boolean): ()
    local theme = preferences.theme
    local lines: {string} = {}
    for _, line in ipairs(LOGO) do lines[#lines + 1] = line end
    if width < 24 or height < 14 then lines = {} end
    if starting and height >= 5 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Starting…"
    end
    local top = math.floor(math.max(2, (height - #lines) / 2))
    if height < 3 then top = 1 end
    for index, text in ipairs(lines) do
        local y = top + index - 1
        if y < height or height < 3 then
            local x = math.floor(math.max(1, (width - tty.text.width(text)) / 2 + 1))
            local color = starting and theme.accent or theme.border
            canvas:put(x, y, appearance.style(color, theme.ground) .. text .. "\27[0m", math.floor(math.max(0, width - x + 1)))
        end
    end
end
-- loader is the screen a display shows until it knows its node's appearance:
-- the logo and status in the terminal's own colors, so no default theme
-- flashes before the node's.
function M.loader(width: integer, height: integer, status: string): {string}
    local lines: {string} = {}
    if width >= 24 and height >= 10 then
        for _, line in ipairs(LOGO) do lines[#lines + 1] = line end
        lines[#lines + 1] = ""
    end
    lines[#lines + 1] = tty.text.truncate(status, math.floor(math.max(1, width - 2)), "…")
    local rows: {string} = {}
    local top = math.floor(math.max(0, (height - #lines) / 2))
    for y = 1, height do
        local text = lines[y - top] or ""
        local left = math.floor(math.max(0, (width - tty.text.width(text)) / 2))
        rows[y] = string.rep(" ", left) .. text .. string.rep(" ", math.floor(math.max(0, width - left - tty.text.width(text))))
    end
    return rows
end
return M

-- MIT. The short-lived Agent continuation surface shown while admission runs.
-- It has no process or workspace authority; it only renders bounded status.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
local RESET = "\27[0m"

local function maximum(a: integer, b: integer): integer
    if a > b then return a end
    return b
end

local function line(canvas: tty.Canvas, width: integer, height: integer, y: integer,
    value: string, foreground: string, background: string)
    if y < 1 or y > height or width <= 2 then return end
    local clean = value:gsub("%c", " ")
    local room = maximum(0, width - 4)
    local shown = tty.text.truncate(clean, room, "…")
    local style = appearance.style(foreground, background)
    canvas:put(2, y, style .. shown .. RESET, room)
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, status: string): {rows: {string}}
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(canvas, width, height, 1, "AGENT", theme.text, theme.surface)
    line(canvas, width, height, 3, "Restoring Agent", theme.text, theme.surface)
    line(canvas, width, height, 5, status, theme.accent, theme.surface)
    line(canvas, width, height, height - 1, "Esc or Ctrl+Q cancels recovery", theme.muted, theme.surface)
    return {rows = canvas:rows()}
end

return M

-- Window decoration owns no state. Layout supplies the exact control hit cells.
local tty = require("tty")
local model = require("model")
local layout = require("layout")
local appearance = require("appearance")
local M = {}
function M.draw(canvas: tty.Canvas, win: model.Window, rect: model.Rect, active: boolean, theme: appearance.Theme)
    local accent = appearance.instance_accent(theme, win.accent)
    local edge = appearance.style(active and accent or theme.border, theme.surface)
    local title_style = appearance.style(active and theme.text or theme.muted, theme.surface)
    local controls = layout.controls(win, rect)
    local stop = rect.x + rect.width - 1
    if #controls > 0 then stop = controls[1].x end
    local room = math.floor(math.max(0, stop - rect.x - 3))
    local title = tty.text.truncate(string.gsub(model.display_title(win), "%c", " "), room, "…")
    if win.mode == "collapsed" then
        canvas:put(rect.x, rect.y, title_style .. string.rep(" ", rect.width) .. "\27[0m", rect.width)
    else
        canvas:put(rect.x, rect.y, edge .. "╭" .. string.rep("─", math.floor(math.max(0, rect.width - 2))) .. "╮\27[0m", rect.width)
    end
    if room > 0 then canvas:put(rect.x + 2, rect.y, title_style .. " " .. title .. " \27[0m", room + 1) end
    for _, control in ipairs(controls) do
        canvas:put(control.x, control.y, edge .. control.label .. "\27[0m", control.width)
    end
    if rect.height <= 1 then return end
    for y = rect.y + 1, rect.y + rect.height - 2 do
        canvas:put(rect.x, y, edge .. "│\27[0m", 1)
        canvas:put(rect.x + rect.width - 1, y, edge .. "│\27[0m", 1)
    end
    canvas:put(rect.x, rect.y + rect.height - 1,
        edge .. "╰" .. string.rep("─", math.floor(math.max(0, rect.width - 2))) .. "╯\27[0m", rect.width)
end
return M

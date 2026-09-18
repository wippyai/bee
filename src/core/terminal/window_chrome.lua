-- Window decoration owns no state. Layout supplies the exact control hit cells.
local tty = require("tty")
local model = require("model")
local layout = require("layout")
local appearance = require("appearance")
local surface = require("surface")
local M = {}
local function badge_glyph(badge: surface.Badge?): string
    if not badge then return "" end
    return string.gsub(badge.glyph, "%c", " ")
end
local function badge_summary(badge: surface.Badge?): string
    if not badge then return "" end
    local glyph = tty.text.truncate(badge_glyph(badge), 2, "")
    local text = string.gsub(badge.text, "%c", " ")
    if glyph == "" then return text end
    if text == "" then return glyph end
    return glyph .. " " .. text
end
local function badge_style(theme: appearance.Theme, badge: surface.Badge?): string?
    if not badge then return nil end
    if badge.tone == "muted" then return appearance.style(theme.muted, theme.surface) end
    -- The current theme contract has no dedicated success/danger fields;
    -- keep those semantic tones within its existing readable palette.
    if badge.tone == "warning" or badge.tone == "accent" or badge.tone == "danger" then return appearance.style(theme.accent, theme.surface) end
    if badge.tone == "success" then return appearance.style(theme.text, theme.surface) end
    return nil
end
function M.draw(canvas: tty.Canvas, win: model.Window, rect: model.Rect, active: boolean, theme: appearance.Theme, badge: surface.Badge?)
    local accent = appearance.instance_accent(theme, win.accent)
    local edge = appearance.style(active and accent or theme.border, theme.surface)
    local title_style = appearance.style(active and theme.text or theme.muted, theme.surface)
    local controls = layout.controls(win, rect)
    local stop = rect.x + rect.width - 1
    if #controls > 0 then stop = controls[1].x end
    local room = math.floor(math.max(0, stop - rect.x - 3))
    local base_title = string.gsub(model.display_title(win), "%c", " ")
    local summary = badge_summary(badge)
    local full_title = summary ~= "" and summary .. " " .. base_title or base_title
    local title = tty.text.truncate(full_title, room, "…")
    if win.mode == "collapsed" then
        canvas:put(rect.x, rect.y, title_style .. string.rep(" ", rect.width) .. "\27[0m", rect.width)
    else
        canvas:put(rect.x, rect.y, edge .. "╭" .. string.rep("─", math.floor(math.max(0, rect.width - 2))) .. "╮\27[0m", rect.width)
    end
    if room > 0 then
        local decorated = title_style .. " "
        local status = badge_style(theme, badge)
        local summary_width = tty.text.width(summary)
        if status and summary ~= "" and tty.text.width(title) >= summary_width then
            decorated = decorated .. status .. tty.text.cut(title, 0, summary_width) .. title_style
            decorated = decorated .. tty.text.cut(title, summary_width, tty.text.width(title))
        else
            decorated = decorated .. title
        end
        canvas:put(rect.x + 2, rect.y, decorated .. " \27[0m", room + 1)
    end
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

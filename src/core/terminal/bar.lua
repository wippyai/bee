-- Compact application/status bar. Drawing and input share the returned hits.
local tty = require("tty")
local model = require("model")
local appearance = require("appearance")
local surface = require("surface")
type TabHit = {id: string, x: integer, width: integer, action: string?}
type Frame = {text: string, hits: {TabHit}}
local M = {}
type Strip = {text: string, hits: {TabHit}}
local function badge_glyph(badge: surface.Badge?): string
    if not badge then return "" end
    return string.gsub(badge.glyph, "%c", " ")
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
local function mode_marker(win: model.Window): string
    return win.mode == "fullscreen" and "▣ " or (win.mode == "minimized" and "− " or (win.mode == "collapsed" and "▸ " or ""))
end
local function tabstrip(scene: model.Scene, order: {string}, width: integer, icons: boolean, badges: {[string]: surface.Badge}?): Strip
    local labels: {string} = {}
    local ids: {string} = {}
    local focused = 1
    for _, id in ipairs(order) do
        for _, win in ipairs(scene.windows) do
            if win.id == id then
                local title = tty.text.truncate(string.gsub(model.display_title(win), "%c", " "), math.floor(math.max(1, math.min(22, width - 7))), "…")
                if icons then
                    title = tty.text.truncate(win.icon ~= nil and win.icon ~= "" and win.icon or title, 2, "")
                    if tty.text.width(title) == 0 then title = "•" end
                end
                local glyph = tty.text.truncate(badge_glyph(badges and badges[id] or nil), 2, "")
                if glyph ~= "" then title = glyph .. " " .. title end
                local badge = mode_marker(win)
                labels[#labels + 1] = " " .. badge .. title .. " "
                ids[#ids + 1] = id
                if win.id == scene.focus then focused = #labels end
            end
        end
    end
    local first, span = 1, 0
    for index = 1, focused do span = span + tty.text.width(labels[index] or "") end
    while first < focused and span > width - 5 do span = span - tty.text.width(labels[first]); first = first + 1 end
    local text = " "
    local hits: {TabHit} = {}
    if first > 1 and width >= 5 then
        text = "‹ "
        hits[#hits + 1] = {id = ids[first - 1], x = 1, width = 2}
    end
    local last = first - 1
    for index = first, #labels do
        local x = tty.text.width(text) + 1
        local available = width - x + 1 - (index < #labels and 2 or 0)
        if available < 1 or (index > first and tty.text.width(labels[index]) > available) then break end
        local label = tty.text.truncate(labels[index], available, "…")
        hits[#hits + 1] = {id = ids[index], x = x, width = tty.text.width(label)}
        text = text .. label
        last = index
    end
    if last < #ids and tty.text.width(text) + 2 <= width then
        hits[#hits + 1] = {id = ids[last + 1], x = tty.text.width(text) + 1, width = 2}
        text = text .. "› "
    end
    return {text = text, hits = hits}
end

function M.draw(scene: model.Scene, order: {string}, status: string, label: string,
    preferences: appearance.Preferences, opened: boolean, badges: {[string]: surface.Badge}?): Frame
    status = string.gsub(status, "%c", " ")
    label = string.gsub(label, "%c", " ")
    local theme = appearance.theme(preferences.theme)
    local normal = appearance.style(theme.text, theme.surface)
    local muted = appearance.style(theme.muted, theme.surface)
    local active = appearance.style(appearance.selection_text(theme), theme.accent)
    local width = scene.width
    local restore_id = ""
    for _, win in ipairs(model.visible(scene)) do
        if win.mode == "fullscreen" then restore_id = win.id; break end
    end
    local restore = restore_id ~= "" and width >= 36 and " −  ◇  × " or ""
    local right = ""
    if status ~= "" and width >= 36 then right = " " .. status .. " "
    elseif width >= 60 then right = " " .. label .. " " end
    right = tty.text.truncate(right, math.floor(math.max(0, width // 2)))
    local room = math.floor(math.max(0, width - 7 - tty.text.width(right) - tty.text.width(restore)))
    local strip = tabstrip(scene, order, room, preferences.taskbar == "icons", badges)
    local text = active .. (opened and " BEE ▴ " or " BEE ▾ ") .. normal
    local hits: {TabHit} = {}
    -- Style each application independently without changing its hit geometry.
    local position = 1
    for _, hit in ipairs(strip.hits) do
        if hit.x > position then text = text .. normal .. tty.text.cut(strip.text, position - 1, hit.x - 1) end
        local style = normal
        for _, win in ipairs(scene.windows) do if win.id == hit.id and win.mode == "minimized" then style = muted end end
        for _, win in ipairs(scene.windows) do
            if win.id == hit.id then
                local accent, foreground = appearance.instance_accent(theme, win.accent)
                if hit.id == scene.focus then style = appearance.style(foreground, accent)
                elseif win.mode ~= "minimized" and win.accent and win.accent ~= "" then style = appearance.style(accent, theme.surface) end
            end
        end
        local raw = tty.text.cut(strip.text, hit.x - 1, hit.x + hit.width - 1)
        local badge = badges and badges[hit.id] or nil
        local glyph = tty.text.truncate(badge_glyph(badge), 2, "")
        local status = badge_style(theme, badge)
        if glyph ~= "" and status then
            local status_offset = 1
            for _, win in ipairs(scene.windows) do
                if win.id == hit.id then status_offset = status_offset + tty.text.width(mode_marker(win)); break end
            end
            local glyph_width = tty.text.width(glyph)
            local leading = tty.text.cut(raw, 0, status_offset)
            text = text .. style .. leading .. status .. glyph .. style .. tty.text.cut(raw, status_offset + glyph_width, tty.text.width(raw))
        else
            text = text .. style .. raw
        end
        position = hit.x + hit.width
        hits[#hits + 1] = {id = hit.id, x = hit.x + 7, width = hit.width}
    end
    if #strip.hits == 0 then
        local empty = tty.text.truncate(" No applications open", room)
        text = text .. muted .. empty
        position = tty.text.width(empty) + 1
    end
    text = text .. normal .. string.rep(" ", math.max(0, room - position + 1))
    if restore ~= "" then
        for index, action in ipairs({"minimize", "fullscreen", "close"}) do
            hits[#hits + 1] = {id = restore_id, x = 8 + room + (index - 1) * 3, width = 3, action = action}
        end
        text = text .. appearance.style(theme.accent, theme.surface) .. restore
    end
    text = text .. muted .. right .. "\27[0m"
    return {text = text, hits = hits}
end
return M

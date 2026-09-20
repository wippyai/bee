-- Pure, responsive reference frame. No calls, polling or mutable ownership.
local tty = require("tty")
local appearance = require("appearance")

type Hit = {kind: string, index: integer, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}}
local M = {}
local RESET = "\27[0m"
local sections = {"Principles", "Components", "States", "Layout"}
local samples: {{{string}}} = {
    {{"Ground", "desktop context"}, {"Surface", "application work"},
        {"Accent", "focus and primary action"}, {"Muted", "metadata and disabled controls"}},
    {{"Selected row", "whole-row keyboard and mouse target"},
        {" Run ", "one clear primary action"}, {"Name", "Value stays next to its label"}},
    {{"Ready", "work can begin"}, {"Loading", "catalog from this workspace"},
        {"Waiting", "owner approval"}, {"Unavailable", "node is disconnected · retry"},
        {"Empty", "no runs yet · start one"}},
    {{"Identity", "one dense header"}, {"Work", "selection before detail"},
        {"Feedback", "stable penultimate row"}, {"Actions", "stable final row"}},
}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
function M.section_count(): integer return #sections end
function M.item_count(section: integer): integer return samples[section] and #samples[section] or 1 end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, item in ipairs(hits) do
        if x >= item.x and x < item.x + item.width and y >= item.y and y < item.y + item.height then return item end
    end
    return nil
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, section: integer, selected: integer): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if x < 1 or x > width or y < 1 or y > height or size <= 0 then return end
        local room = math.floor(math.min(size, width - x + 1))
        if room <= 0 then return end
        local safe = tty.text.truncate(value:gsub("%c", " "), room, "…")
        canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. safe .. RESET, room)
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, value, maximum(0, width - 2), fg, bg)
    end
    local function rule(y: integer) put(1, y, string.rep("─", width), width, theme.border) end
    local function row(y: integer, index: integer, title: string, detail: string)
        local active = index == selected
        line(y, "", active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
        local marker = active and "› " or "  "
        if width < 54 then
            put(2, y, marker .. title .. " · " .. detail, maximum(0, width - 2), active and appearance.selection_text(theme) or theme.text,
                active and theme.accent or theme.surface)
        else
            put(2, y, marker .. title, 20, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
            put(24, y, detail, maximum(0, width - 24), active and appearance.selection_text(theme) or theme.muted,
                active and theme.accent or theme.surface)
        end
        hits[#hits + 1] = {kind = "item", index = index, x = 1, y = y, width = width, height = 1}
    end
    local function rows(first: integer, items: {{string}})
        local last = height - 2
        local capacity = math.max(0, last - first + 1)
        if capacity == 0 then return end
        local offset = math.max(0, math.min(#items - capacity, selected - capacity))
        for slot = 1, math.min(capacity, #items - offset) do
            local index = offset + slot
            row(first + slot - 1, index, items[index][1], items[index][2])
        end
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(1, "BEE UI GUIDE", theme.text)
    if width >= 42 then
        local label = "HONEY SYSTEM"
        put(width - #label, 1, label, #label, theme.accent)
    end
    if height >= 4 then
        local x = 2
        for index, title in ipairs(sections) do
            local label = width < 48 and (" " .. title:sub(1, 1) .. " ") or (" " .. title .. " ")
            local size = tty.text.width(label)
            if x <= width then
                local active = index == section
                put(x, 2, label, size, active and appearance.selection_text(theme) or theme.muted,
                    active and theme.accent or theme.surface)
                if x + size - 1 <= width then
                    hits[#hits + 1] = {kind = "section", index = index, x = x, y = 2, width = size, height = 1}
                end
                x = x + size + 1
            end
        end
        rule(3)
    end
    local compact = height >= 5 and height < 12
    if compact then
        local sample = samples[section][selected]
        row(height - 1, selected, sample[1], sample[2])
    elseif height >= 12 and section == 1 then
        line(5, "Calm tools for busy hives.", theme.accent)
        if height >= 7 then line(7, "Semantic color · compact hierarchy · visible focus", theme.text) end
        if height >= 8 then line(8, "Keyboard parity · bounded text · responsive frames", theme.muted) end
        rows(10, samples[1])
    elseif height >= 12 and section == 2 then
        line(5, "CONTROLS", theme.muted)
        if height >= 6 then line(6, "  Disabled · visible, muted, no hit target", theme.muted) end
        rows(8, samples[2])
    elseif height >= 12 and section == 3 then
        line(5, "FEEDBACK", theme.muted)
        if height >= 6 then line(6, "State always has words; color never carries it alone.", theme.muted) end
        rows(8, samples[3])
    elseif height >= 12 then
        line(5, width < 54 and "COMPACT" or "RESPONSIVE LAYOUT", theme.muted)
        if height >= 6 then line(6, width < 54 and "Narrow keeps the next useful action." or "Wide views add detail; narrow views preserve the task.", theme.text) end
        rows(8, samples[4])
    end
    if height >= 3 and not compact then line(height - 1, sections[section] .. " · " .. tostring(selected) .. "/" .. tostring(M.item_count(section)), theme.muted) end
    if height >= 2 then line(height, "←→ / Tab Section   ↑↓ Inspect   Esc Close", theme.muted) end
    return {rows = canvas:rows(), hits = hits}
end

return M

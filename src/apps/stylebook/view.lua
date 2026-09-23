-- Pure, responsive reference frame built from the shared application frame:
-- header, tabs, a table with selection, button roles, an empty state and the
-- status and key-hint footer. No calls, polling or mutable ownership.
local appearance = require("appearance")
local frame = require("frame")

type Frame = {rows: {string}, hits: {frame.Hit}}
local M = {}
local sections: {frame.Tab} = {
    {kind = "principles", label = "Principles", short = "P"},
    {kind = "components", label = "Components", short = "C"},
    {kind = "states", label = "States", short = "S"},
    {kind = "layout", label = "Layout", short = "L"},
}
local samples: {{{string}}} = {
    {{"Ground", "desktop context"}, {"Surface", "application work"},
        {"Accent", "focus and primary action"}, {"Muted", "metadata and disabled controls"}},
    {{"Selected row", "whole-row target, › marker and accent pair"},
        {" Run ", "one clear primary action"}, {"Name", "Value stays next to its label"}},
    {{"Ready", "work can begin"}, {"Loading", "catalog from this workspace"},
        {"Waiting", "owner approval"}, {"Unavailable", "node is disconnected · retry"},
        {"Empty", "no runs yet · start one"}},
    {{"Identity", "header row: title left, muted summary right"}, {"Work", "tables and lists; selection before detail"},
        {"Feedback", "status at the left of the final row"}, {"Actions", "action bar above; key hints beside the status"}},
}
local HINTS = frame.hints({{key = "←→/Tab", verb = "section"}, {key = "↑↓", verb = "inspect"}, {key = "Esc", verb = "close"}})
local COLUMNS: {frame.Column} = {{title = "Element", width = 18}, {title = "Meaning", width = 0}}

function M.section_count(): integer return #sections end
function M.item_count(section: integer): integer return samples[section] and #samples[section] or 1 end
-- The section a tab hit selects, or 0 for any other hit kind.
function M.section_of(kind: string): integer
    for index, tab in ipairs(sections) do if tab.kind == kind then return index end end
    return 0
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, section: integer, selected: integer): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local items = samples[section]
    frame.header(painter, "BEE UI GUIDE", "HONEY SYSTEM")
    if height >= 4 then
        frame.tabs(painter, 2, sections, sections[section].kind)
        frame.rule(painter, 3)
    end
    local function table_at(first: integer)
        local cells: {{string}} = {}
        for index, item in ipairs(items) do cells[index] = {item[1], item[2]} end
        frame.table(painter, first, height - 1, {columns = COLUMNS, cells = cells, kind = "item", selected = selected, offset = 0})
    end
    local compact = height >= 5 and height < 12
    if compact then
        local sample = items[selected]
        frame.row(painter, height - 1, sample[1] .. " · " .. sample[2], true, "item", selected, "")
    elseif height >= 12 and section == 1 then
        frame.line(painter, 5, "Calm tools for busy hives.", theme.accent)
        frame.line(painter, 7, "Semantic color · compact hierarchy · visible focus", theme.text)
        frame.line(painter, 8, "Keyboard parity · bounded text · responsive frames", theme.muted)
        table_at(10)
    elseif height >= 12 and section == 2 then
        frame.line(painter, 5, "CONTROLS", theme.muted)
        local x = frame.put(painter, 2, 6, " Run ", 5, appearance.selection_text(theme), theme.accent) + 3
        x = x + frame.put(painter, x, 6, " Details ", 9, theme.accent) + 1
        frame.put(painter, x, 6, " Disabled · visible, muted, no hit target", painter.width - x, theme.muted)
        table_at(8)
    elseif height >= 12 and section == 3 then
        frame.line(painter, 5, "FEEDBACK", theme.muted)
        frame.line(painter, 6, "State always has words; color never carries it alone.", theme.muted)
        table_at(8)
    elseif height >= 12 then
        frame.line(painter, 5, width < 54 and "COMPACT" or "RESPONSIVE LAYOUT", theme.muted)
        frame.line(painter, 6, width < 54 and "Narrow keeps the next useful action." or "Wide views add detail; narrow views preserve the task.", theme.text)
        table_at(8)
    end
    -- Narrow frames keep the key hints; the position is visible in the selection.
    if height >= 2 then
        local position = sections[section].label .. " · " .. tostring(selected) .. "/" .. tostring(M.item_count(section))
        frame.footer(painter, width >= 60 and position or "", HINTS)
    end
    return {rows = frame.rows(painter), hits = painter.hits}
end

return M

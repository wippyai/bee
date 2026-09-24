-- MIT. Agent profile choices use the display's appearance and bounded text.
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local selection = require("selection")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "N", verb = "new"},
    {key = "E", verb = "edit"}, {key = "R", verb = "refresh"}, {key = "Esc", verb = "close"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    choices: selection.Choices, selected: integer, status: string, busy: boolean?): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    frame.header(painter, "AGENT", #choices.items > 0 and (tostring(#choices.items) .. " profiles") or nil)
    if height >= 5 then frame.line(painter, 2, "Choose a profile", theme.muted) end
    local show_summary = height >= 10
    local last = height - (show_summary and 4 or 3)
    local capacity = math.floor(math.max(0, last - 2))
    if width <= 2 then capacity = 0 end
    local window = frame.window(#choices.items, capacity, selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local choice = choices.items[index]
        if not choice then break end
        local label = text.bound(choice.title, 512) .. (choice.unavailable and " · Unavailable" or "")
        frame.row(painter, slot + 2, label, index == selected, "choice", index, "", choice.unavailable and theme.muted or nil)
    end
    if #choices.items == 0 and status == "" and height >= 5 then
        frame.empty(painter, 3, "No agent profiles are configured on this node", height >= 7 and "Install a harness module, then R refresh" or nil)
    end
    local choice = choices.items[selected]
    if show_summary and choice and choice.summary then frame.line(painter, height - 3, text.bound(choice.summary, 512), theme.muted) end
    if height >= 3 then
        local chosen = choice ~= nil and window.capacity > 0
        frame.actions(painter, height - 1, {
            {kind = "open", label = "Open", enabled = not busy and chosen and choice ~= nil and not choice.unavailable, primary = true},
            {kind = "new", label = "New", enabled = not busy and chosen},
            {kind = "edit", label = "Edit", enabled = not busy and chosen},
            {kind = "refresh", label = "Refresh", enabled = not busy},
            {kind = "close", label = "Close", enabled = true},
        })
    end
    local message = status
    if message == "" and choice and choice.unavailable then message = choice.unavailable end
    if message == "" and choices.unavailable > 0 then message = tostring(choices.unavailable) .. " profiles unavailable" end
    if height >= 2 then frame.footer(painter, text.bound(message, 512), HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M

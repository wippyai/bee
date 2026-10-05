-- MIT. Agent choices from the sessions catalog use the display's appearance
-- and bounded text. Unavailable candidates are shown only on request.
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open a window"}, {key = "H", verb = "open headless"}, {key = "U", verb = "unavailable"},
    {key = "/", verb = "search"}, {key = "Ctrl+S", verb = "sort"}, {key = "R", verb = "refresh"}, {key = "Esc", verb = "back"}, {key = "E", verb = "customize copy or edit"},
    {key = "N", verb = "new profile"}, {key = "S", verb = "setup"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    listing: agents.Listing, selected: integer, status: string, busy: boolean?, show_unavailable: boolean?, query: string?, sort: string?, searching: boolean?): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local count = #listing.items
    frame.header(painter, "NEW SESSION", count > 0 and (tostring(count) .. " agents") or nil)
    if height >= 5 then frame.line(painter, 2, (searching and "Search: " or "Search /: ") .. (query or "") .. " · sort " .. (sort or "name"), theme.muted) end
    local show_summary = height >= 10
    local last = height - (show_summary and 5 or 3)
    local capacity = math.floor(math.max(0, last - 2))
    if width <= 2 then capacity = 0 end
    local window = frame.window(count, capacity, selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = listing.items[index]
        if not item then break end
        local label = text.bound(item.title, 512) .. (item.ready and "" or " · " .. item.status)
        frame.row(painter, slot + 2, label, index == selected, "choice", index, "", not item.ready and theme.muted or nil)
    end
    if count == 0 and status == "" and height >= 5 then
        frame.empty(painter, 3, "No agents are ready on this node",
            height >= 7 and "Install a harness and log in, then R re-probe or U show unavailable" or nil)
    end
    local item = listing.items[selected]
    if show_summary and item then
        local summary = item.ready and "Ready · opening a session starts no work" or "Unavailable"
        if item.reason ~= "" then summary = summary .. " · " .. item.reason end
        frame.line(painter, height - 4, text.bound(summary, 512), theme.muted)
    end
    if height >= 3 then
        local chosen = item ~= nil and window.capacity > 0
        frame.actions(painter, height - 1, {
            {kind = item and not item.ready and "setup" or "open", key = "Enter", label = item and not item.ready and "Setup" or "Open", enabled = not busy and chosen, primary = true},
            {kind = "headless", key = "H", label = "Headless", enabled = not busy and chosen and item ~= nil and item.ready},
            {kind = "unavailable", key = "U", label = show_unavailable and "Hide unavailable" or "Show unavailable", enabled = not busy},
            {kind = "refresh", key = "R", label = "Refresh", enabled = not busy},
            {kind = "search", key = "/", label = "Search", enabled = not busy},
            {kind = "sort", key = "Ctrl+S", label = "Sort " .. (sort or "name"), enabled = not busy},
            {kind = "edit", key = "E", label = item and item.kind == "profile" and "Edit" or "Customize copy", enabled = not busy and chosen},
            {kind = "close", key = "Esc", label = "Back", enabled = true},
        })
    end
    local message = status
    if message == "" and item and not item.ready and item.reason ~= "" then message = item.reason end
    if message == "" and not show_unavailable and listing.unavailable > 0 then
        message = tostring(listing.unavailable) .. " unavailable"
    end
    if height >= 6 then frame.line(painter, height - 2, text.bound(message, 512), theme.text) end
    if height >= 2 then frame.footer(painter, "", HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

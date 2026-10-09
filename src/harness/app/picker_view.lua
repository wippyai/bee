-- MIT. Agent choices from the sessions catalog use the display's appearance
-- and bounded text. Unavailable candidates are shown only on request.
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
-- The footer names only keys the buttons above it do not show; help lists
-- them all.
local HINTS = frame.hints({{key = "/", verb = "search"}})
local MORE = frame.hints({{key = "Enter", verb = "open"}, {key = "Esc", verb = "back"}, {key = "↑↓", verb = "select"}, {key = "E", verb = "customize copy or edit"}, {key = "N", verb = "new profile"},
    {key = "S", verb = "setup"}, {key = "U", verb = "unavailable"}, {key = "R", verb = "refresh"}, {key = "Ctrl+S", verb = "sort"}})
-- The right column names what kind of choice a row is: a saved profile, or
-- why an agent cannot open.
local function tag(item: agents.Entry): string
    if item.needs_setup then return "needs setup" end
    if not item.ready then return text.bound(item.status, 40) end
    if item.kind == "profile" then return "saved profile" end
    return ""
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    listing: agents.Listing, selected: integer, status: string, busy: boolean?, show_unavailable: boolean?, query: string?, sort: string?, searching: boolean?): Frame
    local painter = frame.new(width, height, preferences)
    local footer_buttons: {frame.Button} = {}
    local theme = painter.theme
    local count = #listing.items
    frame.header(painter, "NEW SESSION", count > 0 and (tostring(count) .. " agents") or nil)
    local filtering = searching or (query ~= nil and query ~= "")
    local first = filtering and 3 or 2
    if filtering and height >= 5 then frame.line(painter, 2, "Search: " .. (query or ""), searching and theme.text or theme.muted) end
    local capacity = math.floor(math.max(0, height - 2 - first))
    if width <= 2 then capacity = 0 end
    local window = frame.window(count, capacity, selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = listing.items[index]
        if not item then break end
        frame.row(painter, first + slot - 1, frame.tagged(width, text.bound(item.title, 512), tag(item)), index == selected, "choice", index, "", not item.ready and theme.muted or nil)
    end
    if count == 0 and status == "" and height >= 5 then
        frame.empty(painter, first, "No agents are ready on this node",
            height >= 7 and "Install a harness and log in, then R refresh, or U to see unavailable agents" or nil)
    elseif count == 0 and height >= 5 then
        frame.empty(painter, first, text.bound(status, 512))
    end
    local item = listing.items[selected]
    local message = count == 0 and "" or status
    if message == "" and item and (not item.ready or item.needs_setup) and item.reason ~= "" then message = item.reason end
    if message == "" and not show_unavailable and listing.unavailable > 0 then
        message = tostring(listing.unavailable) .. " unavailable · U to show"
    end
    if height >= 6 and message ~= "" then frame.line(painter, height - 2, text.bound(message, 512), theme.muted) end
    if height >= 3 then
        local chosen = item ~= nil and window.capacity > 0
        footer_buttons = {
            {kind = item and (not item.ready or item.needs_setup) and "setup" or "open", key = "Enter", label = item and (not item.ready or item.needs_setup) and "Setup" or "Open", enabled = not busy and chosen, primary = true},
            {kind = "edit", key = "E", label = item and item.kind == "profile" and "Edit" or "Customize", enabled = not busy and chosen},
            {kind = "new", key = "N", label = "New profile", enabled = not busy and chosen and item ~= nil and (item.ready or item.status == "unconfigured")},
            {kind = "close", key = "Esc", label = "Back", enabled = true},
        }
    end
    if height >= 2 then frame.footer(painter, "", HINTS, MORE, footer_buttons) end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

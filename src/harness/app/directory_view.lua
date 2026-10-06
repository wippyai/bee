-- MIT. Sessions as a short list: each session's title and state, then its
-- last reply. Opening one shows its live terminal.
local frame = require("frame")
local appearance = require("appearance")
local text = require("text")
local protocol = require("protocol")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
-- The footer names only keys the buttons above it do not show; help lists
-- them all.
local HINTS = frame.hints({{key = "Esc", verb = "back"}})
local MORE = frame.hints({{key = "Enter", verb = "open"}, {key = "N", verb = "new"}, {key = "X", verb = "close"}, {key = "↑↓", verb = "select"},
    {key = "W", verb = "this workspace or all"}, {key = "C", verb = "closed sessions"}, {key = "R", verb = "refresh"}})

-- state names what the session is doing in a word a person reads at a glance.
local function state(item: protocol.SessionSnapshot): string
    if item.lifecycle == "closed" then return "closed" end
    if item.lifecycle == "closing" then return "closing" end
    if item.lifecycle == "suspended" then return "stopped · resumes on its next message" end
    if item.activity == "working" or item.activity == "stalled" then return item.activity end
    if item.activity == "blocked" then return "needs you" end
    return "idle"
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    rows: {protocol.SessionSnapshot}, selected: integer, status: string, filtered: boolean, workspaces: {[string]: agents.Workspace}?,
    show_closed: boolean?): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, false, true)
    local scope = filtered and "this workspace" or nil
    frame.header(painter, "SESSIONS", tostring(#rows) .. (#rows == 1 and " session" or " sessions") .. (scope and (" · " .. scope) or ""))
    local names: {[string]: agents.Workspace} = workspaces or {}
    local capacity = math.floor(math.max(0, (layout.work.height - 1) / 2))
    local window = frame.window(#rows, capacity, selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = rows[index]
        if not item then break end
        local y = layout.work.y + (slot - 1) * 2
        frame.row(painter, y, frame.tagged(width, text.bound(item.title, 512), state(item)), index == selected, "session", index, "", nil, true, 2)
        local last = item.last_result
        local home = agents.home(item.session)
        local workspace = home and names[home]
        local detail = last and last.summary or (workspace and workspace.label or "No reply yet")
        frame.line(painter, y + 1, text.bound(detail, 512), painter.theme.muted)
    end
    if #rows == 0 and status == "" then frame.empty(painter, layout.work.y, "No sessions yet", "N starts one") end
    if height >= 6 and status ~= "" then frame.line(painter, height - 2, text.bound(status, 512), painter.theme.text) end
    if height >= 6 then
        local chosen = rows[selected]
        local buttons: {frame.Button} = {}
        if #rows > 0 then buttons[#buttons + 1] = {kind = "open", key = "Enter", label = "Open", enabled = chosen ~= nil, primary = true} end
        buttons[#buttons + 1] = {kind = "new_session", key = "N", label = "New", enabled = true, primary = #rows == 0}
        if #rows > 0 then buttons[#buttons + 1] = {kind = "close_listed", key = "X", label = "Close", enabled = chosen ~= nil and chosen.lifecycle ~= "closed" and chosen.lifecycle ~= "closing"} end
        frame.actions(painter, height - 1, buttons)
    end
    frame.footer(painter, "", HINTS, MORE .. (show_closed and " · closed shown" or ""))
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

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
local MORE = frame.hints({{key = "Enter", verb = "open"}, {key = "N", verb = "start agent"}, {key = "X", verb = "close"}, {key = "D", verb = "delete"}, {key = "E", verb = "rename"}, {key = "↑↓", verb = "select"},
    {key = "W", verb = "this workspace or all"}, {key = "C", verb = "closed sessions"}, {key = "R", verb = "refresh"}, {key = "A", verb = "agent allowances"}})

-- actions are what a session row offers on a right click or Shift+F10, in
-- the session list and in an open session's sidebar.
function M.actions(item: protocol.SessionSnapshot): {frame.Button}
    local controlled = not item.node or item.peer_scope == "open"
    return {
        {kind = "open", key = "Enter", label = "Open", enabled = true},
        {kind = "rename_listed", key = "E", label = "Rename…", enabled = controlled},
        {kind = "close_listed", key = "X", label = "Close", enabled = controlled and item.lifecycle ~= "closed" and item.lifecycle ~= "closing"},
        {kind = "remove_listed", key = "D", label = "Delete…", enabled = controlled},
    }
end

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
    local footer_buttons: {frame.Button} = {}
    local layout = frame.layout(painter, false, true)
    local scope = filtered and " · this workspace" or ""
    frame.header(painter, "SESSIONS", tostring(#rows) .. (#rows == 1 and " session" or " sessions") .. scope .. (show_closed and " · closed shown" or ""))
    local names: {[string]: agents.Workspace} = workspaces or {}
    -- A status of two lines, such as a question and its choices, takes one
    -- more row above the status row.
    local question, answer = status:match("^([^\n]*)\n(.*)$")
    local capacity = math.floor(math.max(0, (layout.work.height - (question and 2 or 1)) / 3))
    local window = frame.window(#rows, capacity, selected, 0)
    local y = layout.work.y
    local previous_bee: string? = nil
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = rows[index]
        if not item then break end
        local bee = item.node or "This bee"
        if bee ~= previous_bee then
            frame.line(painter, y, "Bee · " .. bee, painter.theme.muted)
            y = y + 1
            previous_bee = bee
        end
        frame.row(painter, y, frame.tagged(width, text.bound(agents.label(item.provider, item.title), 512), state(item)), index == selected, "session", index, item.session, nil, true, 2)
        frame.row_actions(painter, {kind = "session", index = index, key = item.session, selected = index == selected, actions = M.actions(item)})
        local last = item.last_result
        local home = agents.home(item.session)
        local workspace = home and names[home]
        local detail = last and last.summary or (workspace and workspace.label or "No reply yet")
        frame.line(painter, y + 1, text.bound(detail, 512), painter.theme.muted)
        y = y + 2
    end
    if #rows == 0 and status == "" then frame.empty(painter, layout.work.y, "No sessions yet", "Start an agent to open one") end
    if height >= 7 and question and answer then
        frame.line(painter, height - 3, text.bound(question, 512), painter.theme.text)
        frame.line(painter, height - 2, text.bound(answer, 512), painter.theme.text)
    elseif height >= 6 and status ~= "" then frame.line(painter, height - 2, text.bound(status, 512), painter.theme.text) end
    if height >= 6 then
        local buttons: {frame.Button} = {}
        if #rows > 0 then buttons[#buttons + 1] = {kind = "open", key = "Enter", label = "Open", enabled = rows[selected] ~= nil, primary = true} end
        buttons[#buttons + 1] = {kind = "new_session", key = "N", label = "Start agent", enabled = true, primary = #rows == 0}
        buttons[#buttons + 1] = {kind = "profiles", key = "P", label = "Profiles", enabled = true}
        buttons[#buttons + 1] = {kind = "allowances", key = "A", label = "Allowances", enabled = true, more = true}
        buttons[#buttons + 1] = {kind = "mcp_clients", key = "M", label = "MCP clients", enabled = true, more = true}
        footer_buttons = buttons
    end
    frame.footer(painter, "", HINTS, MORE, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

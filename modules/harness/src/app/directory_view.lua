-- MIT. Addressable sessions from the public catalog; lifecycle and activity stay separate.
local frame = require("frame")
local appearance = require("appearance")
local text = require("text")
local protocol = require("protocol")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    rows: {protocol.SessionSnapshot}, selected: integer, status: string, filtered: boolean, workspaces: {[string]: agents.Workspace}?, filter_label: string?): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, false, true)
    frame.header(painter, "SESSIONS", tostring(#rows) .. " sessions")
    if height >= 5 then frame.line(painter, 2, filtered and ("Workspace: " .. text.bound(filter_label or "current", 512)) or "Workspace: all permitted", painter.theme.muted) end
    local names: {[string]: agents.Workspace} = workspaces or {}
    local cells: {{string}} = {}
    for _, item in ipairs(rows) do
        local home = agents.home(item.session)
        local workspace = home and names[home]
        local location = workspace and (workspace.label .. " · " .. workspace.folder) or "Workspace unavailable"
        local activity = item.activity
        if item.activity_evidence then
            activity = activity .. " · quiet " .. tostring(item.activity_evidence.quiet_for_ms) .. " ms"
        end
        cells[#cells + 1] = {text.bound(item.title, 512), item.provider or "—", activity, text.bound(location, 512), item.lifecycle}
    end
    local last = layout.work.y + layout.work.height - 2
    local window = frame.table(painter, layout.work.y, last, {columns = {
        {title = "Session", width = 0}, {title = "Provider", width = 12}, {title = "Activity", width = 10}, {title = "Workspace · folder", width = 28},
        {title = "State", width = 10}}, cells = cells, kind = "session", selected = selected, offset = 0, focused = true})
    if #rows == 0 and status == "" then frame.empty(painter, layout.work.y, "No sessions yet", "N new session · choose an agent, then send work") end
    if height >= 6 then frame.line(painter, height - 2, text.bound(status, 512), painter.theme.text) end
    if height >= 6 then frame.actions(painter, height - 1, {
        {kind = "open", key = "Enter", label = "Open", enabled = rows[selected] ~= nil, primary = true},
        {kind = "new_session", key = "N", label = "New session", enabled = true},
        {kind = "workspace", key = "W", label = filtered and "All workspaces" or "Workspace", enabled = true},
        {kind = "refresh", key = "R", label = "Refresh", enabled = true},
    }) end
    frame.footer(painter, "", "↑↓ select · Enter open · N new · W workspace · R refresh · Esc close")
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

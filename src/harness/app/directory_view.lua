-- MIT. Addressable sessions from the public catalog; lifecycle and activity stay separate.
local frame = require("frame")
local appearance = require("appearance")
local text = require("text")
local protocol = require("protocol")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    rows: {protocol.SessionSnapshot}, selected: integer, status: string, filtered: boolean, workspaces: {[string]: agents.Workspace}?, filter_label: string?,
    show_closed: boolean?): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, false, true)
    frame.header(painter, "SESSIONS", tostring(#rows) .. (#rows == 1 and " session" or " sessions"))
    if height >= 5 then frame.line(painter, 2, filtered and ("Workspace: " .. text.bound(filter_label or "current", 512)) or "Workspace: all permitted", painter.theme.muted) end
    local names: {[string]: agents.Workspace} = workspaces or {}
    local capacity = math.floor(math.max(0, (layout.work.height - 1) / 3))
    local window = frame.window(#rows, capacity, selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = rows[index]
        if not item then break end
        local home = agents.home(item.session)
        local workspace = home and names[home]
        local activity = item.activity
        if item.activity_evidence then
            activity = activity .. " · quiet " .. tostring(item.activity_evidence.quiet_for_ms) .. " ms"
        end
        local location = workspace and (workspace.label .. " · " .. workspace.folder) or "Workspace unavailable"
        local last = item.last_result
        local at = last and last.at or item.execution and item.execution.evidence_at or ""
        local time = at:match("T(%d%d:%d%d)") or at
        local y = layout.work.y + (slot - 1) * 3
        frame.row(painter, y, activity .. " · " .. text.bound(item.title, 512) .. (item.lifecycle ~= "active" and " · " .. item.lifecycle or ""), index == selected, "session", index, "", nil, true, 3)
        frame.line(painter, y + 1, text.bound(location, 512) .. (time ~= "" and " · " .. time .. " UTC" or ""), painter.theme.muted)
        frame.line(painter, y + 2, last and text.bound(last.summary, 512) or "No result yet", painter.theme.muted)
    end
    if #rows == 0 and status == "" then frame.empty(painter, layout.work.y, "No sessions yet", "N new session · choose an agent, then send work") end
    if height >= 6 then frame.line(painter, height - 2, text.bound(status, 512), painter.theme.text) end
    if height >= 6 then
        local buttons: {frame.Button} = {{kind = "new_session", key = "N", label = "New session", enabled = true, primary = #rows == 0}}
        if #rows > 0 then
            table.insert(buttons, 1, {kind = "open", key = "Enter", label = "Open", enabled = rows[selected] ~= nil, primary = true})
            local chosen = rows[selected]
            buttons[#buttons + 1] = {kind = "close_listed", key = "X", label = "Close", enabled = chosen ~= nil and chosen.lifecycle == "active"}
            buttons[#buttons + 1] = {kind = "workspace", key = "W", label = filtered and "All workspaces" or "Workspace", enabled = true}
            buttons[#buttons + 1] = {kind = "refresh", key = "R", label = "Refresh", enabled = true}
        end
        buttons[#buttons + 1] = {kind = "closed", key = "C", label = show_closed and "Hide closed" or "Show closed", enabled = true}
        frame.actions(painter, height - 1, buttons)
    end
    frame.footer(painter, "", "↑↓ select · Enter open · N new · X close session · C closed · W workspace · R refresh · Esc close")
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

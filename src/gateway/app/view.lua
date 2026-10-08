-- SPDX-License-Identifier: MIT
local frame = require("frame")
local appearance = require("appearance")
local M = {}
type Client = {client_id: string, name: string, status: string, thread_id: string, expires_at: string}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, clients: {Client}, selected: integer, status: string, records: string?): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, false, true)
    frame.header(painter, "MCP CLIENTS", tostring(#clients) .. " clients")
    local chosen = clients[selected]
    if records then
        local y = layout.work.y
        for line in records:gmatch("[^\n]+") do
            if y >= layout.work.y + layout.work.height then break end
            frame.line(painter, y, line, painter.theme.text)
            y = y + 1
        end
    else
        local window = frame.window(#clients, layout.work.height, selected, 0)
        for slot = 1, window.capacity do
            local index = window.offset + slot
            local item = clients[index]
            if not item then break end
            frame.row(painter, layout.work.y + slot - 1, frame.tagged(width, item.name, item.status), index == selected, "client", index, "")
        end
        if #clients == 0 then frame.empty(painter, layout.work.y, "No external clients", "Run bee mcp connect in this folder to pair one") end
    end
    if height >= 4 then
        frame.actions(painter, height - 1, {
            {kind = "read", key = "Enter", label = "Tool calls", enabled = chosen ~= nil, primary = true},
            {kind = "revoke", key = "X", label = "Revoke", enabled = chosen ~= nil and chosen.status ~= "revoked" and chosen.status ~= "expired"},
            {kind = "refresh", key = "R", label = "Refresh", enabled = true},
        })
    end
    frame.footer(painter, status, frame.hints({{key = "↑↓", verb = "select"}, {key = "Esc", verb = records and "back" or "close"}}))
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M

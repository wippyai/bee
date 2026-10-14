-- SPDX-License-Identifier: MIT
local frame = require("frame")
local appearance = require("appearance")
local markdown = require("markdown")
local M = {}
type Client = {client_id: string, name: string, status: string, thread_id: string, expires_at: string}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer, total: integer}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, clients: {Client}, selected: integer, status: string, records: string?, guide: string?, offset: integer?): Frame
    local painter = frame.new(width, height, preferences)
    local footer_buttons: {frame.Button} = {}
    local layout = frame.layout(painter, false, true)
    frame.header(painter, "MCP CLIENTS", tostring(#clients) .. " clients")
    local chosen = clients[selected]
    local connecting = not records and (#clients == 0 or guide ~= nil)
    local window: frame.Window = {capacity = layout.work.height, offset = 0}
    local total = 0
    if connecting then
        local first = layout.work.y
        if #clients == 0 then
            frame.empty(painter, first, "No external clients", "Connect a client from another terminal")
            first = first + 3
        end
        local lines = markdown.lines(guide or "## How to connect\n\nConnection guide is unavailable. R refresh to try again.", layout.work.width)
        total = #lines
        window = frame.document(painter, first, layout.work.y + layout.work.height - 1, lines, offset or 0, 0)
    elseif records then
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
    end
    if height >= 4 then
        if connecting then
            footer_buttons = {{kind = "refresh", key = "R", label = "Refresh", enabled = true, primary = true}}
            if #clients > 0 then footer_buttons[#footer_buttons + 1] = {kind = "back", key = "Esc", label = "Clients", enabled = true} end
        else
            footer_buttons = {
                {kind = "read", key = "Enter", label = "Tool calls", enabled = chosen ~= nil, primary = true},
                {kind = "connect", key = "H", label = "How to connect", enabled = true},
                {kind = "refresh", key = "R", label = "Refresh", enabled = true},
                {kind = "revoke", key = "X", label = "Revoke", enabled = chosen ~= nil and chosen.status ~= "revoked" and chosen.status ~= "expired"},
            }
        end
    end
    frame.footer(painter, status, frame.hints({{key = "↑↓", verb = connecting and "scroll" or "select"}, {key = "PgUp/PgDn", verb = "page"}, {key = "Esc", verb = (records or (#clients > 0 and connecting)) and "back" or "close"}}), nil, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset, total = total}
end
return M

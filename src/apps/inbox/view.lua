-- MIT. The inbox frame: rows of requests, the selected request's proposed
-- effect first with technical details behind a toggle, explicit actions
-- and the status line. Every text comes through the model's bounding; the
-- view interprets nothing.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local names = require("names")
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local M = {}
local function state_label(row: model.Row): string
    if row.state == "decided" then return row.decision or "decided" end
    return row.state
end
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "A", verb = "approve"},
    {key = "D", verb = "deny"}, {key = "W", verb = "withdraw"}, {key = "R", verb = "refresh"}, {key = "T", verb = "details"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, rows: {model.Row}, offset: integer, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local pending_total = 0
    for _, row in ipairs(rows) do if row.state == "pending" then pending_total = pending_total + 1 end end
    frame.header(painter, "APPROVALS", #rows == 0 and "" or (tostring(pending_total) .. " pending · " .. tostring(#rows) .. " shown"))
    local detail = state.detail
    local selected = model.selected_row(state)
    local detail_rows = 0
    if detail and selected and detail.approval_id == selected.approval_id and height >= 12 then
        detail_rows = math.floor(math.max(6, math.min(height - 8, state.technical and 14 or 8)))
    end
    local list_first = 3
    local list_last = height - 2 - detail_rows
    local selected_index = 0
    if selected then
        for index, row in ipairs(rows) do if row.approval_id == selected.approval_id then selected_index = index end end
    end
    local window = frame.window(#rows, list_last - list_first + 1, selected_index, offset)
    if #rows == 0 and list_last >= list_first then
        frame.empty(painter, list_first, "No requests", list_last > list_first and "Requests that need your decision appear here · R refresh" or nil)
    end
    for slot = 1, window.capacity do
        local row = rows[window.offset + slot]
        if not row then break end
        local label = string.format("%-9s %s %s", state_label(row), row.effect, row.target)
        if width >= 60 then label = label .. "  from " .. row.requester_id .. "  until " .. row.expires_at end
        frame.row(painter, list_first + slot - 1, label, window.offset + slot == selected_index, "row", window.offset + slot, row.approval_id)
    end
    if detail and selected and detail_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {
            "Effect: " .. selected.effect .. "  target " .. selected.target,
            "Asked: " .. selected.prompt,
            "Requester: " .. selected.requester_id .. "  owner " .. selected.owner_node .. "  policy " .. selected.policy,
            "State: " .. state_label(selected) .. (selected.decider_id and (" by " .. selected.decider_id) or "") .. "  expires " .. selected.expires_at,
        }
        if state.technical then
            lines[#lines + 1] = "Request " .. selected.approval_id .. "  revision " .. tostring(selected.revision) .. "  incarnation observed " .. tostring(selected.owner_incarnation)
            lines[#lines + 1] = "Digest " .. model.text(detail.proposal_digest, 80) .. "  kind " .. selected.request_kind
            for _, payload_line in ipairs(model.payload_lines(detail)) do lines[#lines + 1] = payload_line end
        end
        for index, value in ipairs(lines) do
            if index > detail_rows - 1 then break end
            frame.line(painter, y + index, value, theme.text)
        end
    end
    local pending_detail = detail ~= nil and selected ~= nil and detail.approval_id == selected.approval_id and detail.state == "pending"
    local idle = state.pending == nil
    if height >= 4 then
        local can_open = selected ~= nil and detail == nil
        frame.actions(painter, height - 1, {
            {kind = "open", label = "Open", enabled = can_open, primary = true},
            {kind = "approve", label = "Approve", enabled = pending_detail and idle, primary = true},
            {kind = "deny", label = "Deny", enabled = pending_detail and idle},
            {kind = "withdraw", label = "Withdraw", enabled = pending_detail and idle},
            {kind = "refresh", label = "Refresh", enabled = idle},
            {kind = "technical", label = state.technical and "Hide details" or "Details", enabled = detail ~= nil},
        })
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" and state.pending then message = "Waiting for the approval owner…" end
    for _, workspace in ipairs(state.workspaces) do
        local unavailable = state.unavailable[workspace]
        if message == "" and unavailable then
            local label = names.label(workspace)
            if state.technical then label = label .. " (" .. workspace .. ")" end
            message = "Workspace " .. label .. " unavailable: " .. unavailable
        end
    end
    frame.footer(painter, message, HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M

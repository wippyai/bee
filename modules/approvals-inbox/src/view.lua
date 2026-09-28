-- MIT. The inbox frame: rows of requests, the selected request's proposed
-- effect first with technical details behind a toggle, explicit actions
-- and the status line. Every text comes through the model's bounding; the
-- view interprets nothing.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local leases = require("leases")
local names = require("names")
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local M = {}
local function state_label(row: model.Row): string
    if row.state == "decided" then return row.decision or "decided" end
    return row.state
end
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "A", verb = "approve"},
    {key = "D", verb = "deny"}, {key = "W", verb = "withdraw"}, {key = "R", verb = "refresh"}})
local WIDE_HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "A", verb = "approve"},
    {key = "D", verb = "deny"}, {key = "W", verb = "withdraw"}, {key = "R", verb = "refresh"}, {key = "M", verb = "mark"},
    {key = "B/N", verb = "batch"}, {key = "L", verb = "lease"}, {key = "G", verb = "grant"}, {key = "V", verb = "leases"}})
local LEASE_HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "X", verb = "revoke"}, {key = "R", verb = "refresh"}, {key = "V", verb = "requests"}})
local function lease_label(row: leases.Row): string
    local used = tostring(row.applies_used) .. "/" .. (row.max_applies and tostring(row.max_applies) or "-")
    return string.format("%-9s %s  used %s%s", row.state, row.target, used, row.expires_at and ("  until " .. row.expires_at) or "")
end
local function draw_leases(width: integer, height: integer, preferences: appearance.Preferences, slice: leases.Slice, offset: integer, status: string, notice: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local rows = leases.rows(slice)
    local active = 0
    for _, row in ipairs(rows) do if row.state == "active" then active = active + 1 end end
    frame.header(painter, "LEASES", tostring(active) .. " active · " .. tostring(#rows) .. " shown")
    local selected = leases.selected(slice)
    local detail_rows = selected and height >= 12 and math.floor(math.min(height - 5, 4 + #selected.envelope_lines)) or 0
    local list_first, list_last = 3, height - 2 - detail_rows
    local selected_index = 0
    for index, row in ipairs(rows) do
        if selected and row.source == selected.source and row.lease_id == selected.lease_id then selected_index = index end
    end
    local window = frame.window(#rows, list_last - list_first + 1, selected_index, offset)
    if #rows == 0 and list_last >= list_first then
        frame.empty(painter, list_first, "No leases", "Approve a lease request, then press G to grant it · R refresh")
    end
    for slot = 1, window.capacity do
        local row = rows[window.offset + slot]
        if not row then break end
        frame.row(painter, list_first + slot - 1, lease_label(row), window.offset + slot == selected_index, "lease", window.offset + slot, row.lease_id)
    end
    if selected and detail_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {"Target: " .. selected.target .. "  granted by " .. selected.granted_by,
            "Used " .. tostring(selected.applies_used) .. (selected.max_applies and (" of " .. tostring(selected.max_applies)) or "")
                .. " · " .. tostring(selected.uses) .. " recorded" .. (selected.expires_at and (" · expires " .. selected.expires_at) or "")}
        for _, line in ipairs(selected.envelope_lines) do lines[#lines + 1] = "Envelope: " .. line end
        for index, value in ipairs(lines) do
            if index > detail_rows - 1 then break end
            frame.line(painter, y + index, value, theme.text)
        end
    end
    if height >= 4 then
        frame.actions(painter, height - 1, {
            {kind = "revoke", label = "Revoke", enabled = selected ~= nil and selected.state == "active", primary = true},
            {kind = "refresh", label = "Refresh", enabled = true},
            {kind = "requests", label = "Requests", enabled = true},
        })
    end
    frame.footer(painter, status ~= "" and status or notice, LEASE_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, rows: {model.Row}, offset: integer, status: string, slice: leases.Slice): Frame
    if slice.leases_view then return draw_leases(width, height, preferences, slice, offset, status, slice.notice) end
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local pending_total = 0
    for _, row in ipairs(rows) do if row.state == "pending" then pending_total = pending_total + 1 end end
    frame.header(painter, "APPROVALS", #rows == 0 and "" or (tostring(pending_total) .. " pending · " .. tostring(#rows) .. " shown"))
    local detail = state.detail
    local selected = model.selected_row(state)
    local detail_rows = 0
    local permission_lines: {string} = {}
    if detail and selected and detail.approval_id == selected.approval_id and height >= 12 then
        permission_lines = model.permission_lines(detail)
        local needed = 5 + #permission_lines
        if state.technical then needed = needed + 2 + #model.payload_lines(detail) end
        detail_rows = math.floor(math.max(6, math.min(height - 5, needed)))
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
        local label = string.format("%s%-9s %s %s", slice.marked[row.approval_id] and "[x] " or "", state_label(row), row.effect, row.target)
        if width >= 60 then label = label .. "  from " .. row.requester_id .. "  until " .. row.expires_at end
        frame.row(painter, list_first + slot - 1, label, window.offset + slot == selected_index, "row", window.offset + slot, row.approval_id)
    end
    if detail and selected and detail_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {
            "Effect: " .. selected.effect .. "  target " .. selected.target,
            "Asked: " .. selected.prompt,
        }
        for _, permission_line in ipairs(permission_lines) do
            lines[#lines + 1] = permission_line
        end
        lines[#lines + 1] = "Requester: " .. selected.requester_id .. "  owner " .. selected.owner_node .. "  policy " .. selected.policy
        lines[#lines + 1] = "State: " .. state_label(selected) .. (selected.decider_id and (" by " .. selected.decider_id) or "") .. "  expires " .. selected.expires_at
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
    local marked = #leases.marked(slice, state.rows)
    local lease_source = detail ~= nil and selected ~= nil and detail.approval_id == selected.approval_id
    local can_lease = lease_source and detail.state == "pending" and detail.proposal.ref == leases.ACTIVATION
    local can_grant = lease_source and detail.state == "decided" and detail.decision == "approved" and detail.proposal.ref == leases.PROPOSAL
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
            {kind = "mark", label = "Mark", enabled = selected ~= nil and selected.state == "pending"},
            {kind = "batch_approve", label = "Approve " .. tostring(marked), enabled = marked > 0 and idle},
            {kind = "batch_deny", label = "Deny " .. tostring(marked), enabled = marked > 0 and idle},
            {kind = "lease", label = "Lease", enabled = can_lease and idle},
            {kind = "grant", label = "Grant", enabled = can_grant and idle},
            {kind = "leases", label = "Leases", enabled = true},
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
    frame.footer(painter, message, width >= 130 and WIDE_HINTS or HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M

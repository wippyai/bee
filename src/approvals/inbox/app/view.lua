-- MIT. The inbox frame: rows of requests, the selected request's proposed
-- effect first with technical details behind a toggle, explicit actions
-- and the status line. Every text comes through the model's bounding; the
-- view interprets nothing.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local leases = require("leases")
local names = require("names")
local tty = require("tty")
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
local windows = require("windows")
local M = {}
local function prompt_lines(prompt: string, width: integer): {string}
    local rest = "Asked: " .. prompt
    local room = math.floor(math.max(1, width - 2))
    local lines: {string} = {}
    repeat
        local part = tty.text.cut(rest, 0, room)
        local cut = #part
        if cut < #rest then
            local space = part:find("%s[^%s]*$")
            if space and space > 1 then cut = space - 1 end
        end
        lines[#lines + 1] = rest:sub(1, cut)
        rest = rest:sub(cut + 1):gsub("^%s+", "")
    until rest == ""
    return lines
end
local function state_label(row: model.Row): string
    if model.history(row.view) then return model.history(row.view) or "approved" end
    if row.state == "decided" then return row.decision or "decided" end
    return row.state
end
local HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "A", verb = "approve"},
    {key = "D", verb = "deny"}, {key = "W", verb = "withdraw"}, {key = "R", verb = "refresh"}})
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
        frame.row(painter, list_first + slot - 1, lease_label(row), window.offset + slot == selected_index, "lease_row", window.offset + slot, row.lease_id)
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
            {kind = "revoke", key = "X", label = "Revoke", enabled = selected ~= nil and leases.revocable(selected), primary = true},
            {kind = "refresh", key = "R", label = "Refresh", enabled = true},
            {kind = "requests", key = "V", label = "Requests", enabled = true},
        })
    end
    frame.footer(painter, status ~= "" and status or notice, LEASE_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
local REVIEW_HINTS = frame.hints({{key = "↑↓ PgUp PgDn", verb = "scroll"}, {key = "A", verb = "approve at the end"}, {key = "D", verb = "deny"}, {key = "Esc", verb = "back"}})
local function draw_review(width: integer, height: integer, preferences: appearance.Preferences, state: model.State,
    detail: model.ApprovalView, slice: leases.Slice, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local lines = leases.review_lines(detail, width)
    local visible = math.floor(math.max(1, height - 5))
    local top, complete = leases.review_frame(slice, detail, #lines, visible)
    frame.header(painter, "LEASE APPROVAL", "lines " .. tostring(math.min(#lines, top + visible)) .. " of " .. tostring(#lines))
    for slot = 1, visible do
        local value = lines[top + slot]
        if not value then break end
        frame.line(painter, 2 + slot, value, theme.text)
    end
    if height >= 4 then
        local idle = state.pending == nil
        local buttons: {frame.Button} = {{kind = "approve", key = "A", label = "Allow once", enabled = complete and idle, primary = true}}
        if model.window_cap(state) >= 1800000 then buttons[#buttons + 1] = {kind = "allow_30", key = "F", label = detail.reallow and "Re-allow 30 min" or "Allow 30 min", enabled = complete and idle} end
        if model.window_cap(state) > 1800000 then buttons[#buttons + 1] = {kind = "allow_longer", key = "L", label = "Allow longer", enabled = complete and idle} end
        buttons[#buttons + 1] = {kind = "deny", key = "D", label = "Deny", enabled = idle}
        buttons[#buttons + 1] = {kind = "technical", key = "T", label = state.technical and "Hide details" or "Details", enabled = true}
        frame.actions(painter, height - 1, buttons)
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" and not complete then message = "Scroll to the end of the terms to approve" end
    frame.footer(painter, message, REVIEW_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = visible, offset = 0}
end
local function draw_windows(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "YOUR APPROVAL GRANTS", tostring(#state.grants) .. " active · this node")
    local window = frame.window(#state.grants, height - 5, state.grant_selected, offset)
    if #state.grants == 0 then frame.empty(painter, 3, "No active grants", "Choose a duration on a pending permission request") end
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local grant = state.grants[index]
        if not grant then break end
        local source = state.rows[grant.grant_id]
        local scope = source and (source.effect .. " · " .. source.prompt) or ("exact proposal " .. grant.scope_digest)
        local label = model.text(grant.requester_id, 80) .. " · " .. scope .. " · " .. windows.duration(grant.until_ms - grant.granted_ms) .. " until " .. grant.until_at
        frame.row(painter, 2 + slot, label, index == state.grant_selected, "window_row", index, grant.grant_id)
    end
    if height >= 4 then frame.actions(painter, height - 1, {
        {kind = "window_revoke", key = "X", label = "Revoke now", enabled = state.grants[state.grant_selected] ~= nil, primary = true},
        {kind = "refresh", key = "R", label = "Refresh", enabled = true},
        {kind = "window_back", key = "U", label = "Requests", enabled = true},
    }) end
    frame.footer(painter, status, frame.hints({{key = "↑↓", verb = "select"}, {key = "X", verb = "revoke"}, {key = "U", verb = "requests"}}))
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
-- A pending permission leads with the question and what it lets the agent
-- do; who asks and the exact capability are details (T). An exact version to
-- install is approved once or denied; a repeatable permission may also be
-- allowed for a while.
local function draw_prompt(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, detail: model.ApprovalView, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local group = model.decision_group(state)
    local prefix = detail.reallow and "Re-allow" or "Allow"
    local one_time = detail.proposal.ref == leases.ACTIVATION
    local cap = one_time and 0 or model.window_cap(state)
    frame.header(painter, "NEEDS YOU", tostring(#group) .. (#group == 1 and " request" or " requests · one decision"))
    local lines: {string} = {}
    for _, item in ipairs(group) do
        local summary = model.summary(item, 0)
        for _, line in ipairs(prompt_lines(summary.prompt, width)) do lines[#lines + 1] = line end
        if not one_time then lines[#lines + 1] = "Capability: " .. summary.effect end
        for _, line in ipairs(model.permission_lines(item)) do lines[#lines + 1] = line end
        if not item.proposal.payload.adapter_ref and not one_time then
            lines[#lines + 1] = model.text(table.concat(model.payload_lines(item), " · "), 512)
        end
    end
    if cap >= 1800000 then lines[#lines + 1] = "Allow it once, or for a while with the choices below" end
    local y = 3
    local reserved = state.longer and (1 + #state.longer_choices) or 0
    for _, line in ipairs(lines) do
        if y >= height - 3 - reserved then break end
        frame.line(painter, y, line, painter.theme.text); y = y + 1
    end
    if state.longer then
        frame.line(painter, y, prefix .. " for:", painter.theme.text); y = y + 1
        for index, choice in ipairs(state.longer_choices) do
            if y >= height - 2 then break end
            frame.row(painter, y, tostring(index) .. "  " .. choice.label, false, "window_choice", index, tostring(choice.ttl_ms)); y = y + 1
        end
    end
    local idle = state.pending == nil
    local buttons: {frame.Button} = {{kind = "approve", key = "A", label = one_time and "Approve" or "Allow once", enabled = idle, primary = true}}
    if cap >= 1800000 then buttons[#buttons + 1] = {kind = "allow_30", key = "F", label = prefix .. " 30 min", enabled = idle} end
    if cap > 1800000 then buttons[#buttons + 1] = {kind = "allow_longer", key = "L", label = prefix .. " longer", enabled = idle} end
    buttons[#buttons + 1] = {kind = "deny", key = "D", label = "Deny", enabled = idle}
    if one_time then buttons[#buttons + 1] = {kind = "lease", key = "E", label = "Lease", enabled = idle, more = true} end
    buttons[#buttons + 1] = {kind = "technical", key = "T", label = "Details", enabled = true, more = true}
    buttons[#buttons + 1] = {kind = "windows", key = "U", label = "Your grants", enabled = true, more = true}
    if detail.requesting_session then buttons[#buttons + 1] = {kind = "source", key = "S", label = "Return to source", enabled = true, more = true} end
    if height >= 4 then frame.actions(painter, height - 1, buttons) end
    if status ~= "" or state.notice ~= "" then frame.line(painter, height - 2, status ~= "" and status or state.notice, painter.theme.text) end
    frame.footer(painter, "", frame.hints({{key = "T", verb = "details"}}))
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = 0, offset = 0}
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, rows: {model.Row}, offset: integer, status: string, slice: leases.Slice, workspace_names: {[string]: model.Workspace}?): Frame
    if state.grants_view then return draw_windows(width, height, preferences, state, offset, status) end
    if slice.leases_view then return draw_leases(width, height, preferences, slice, offset, status, slice.notice) end
    local open = state.detail
    local chosen = model.selected_row(state)
    if open and chosen and open.approval_id == chosen.approval_id and leases.is_review(open) and not (state.longer and slice.review_complete) then
        return draw_review(width, height, preferences, state, open, slice, status)
    end
    if open and chosen and open.approval_id == chosen.approval_id and open.state == "pending" and open.request_kind == "permission" and not state.technical then
        return draw_prompt(width, height, preferences, state, open, status)
    end
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local locations: {[string]: model.Workspace} = workspace_names or {}
    local pending_total = 0
    for _, row in ipairs(rows) do if row.state == "pending" then pending_total = pending_total + 1 end end
    frame.header(painter, "NEEDS YOU", #rows == 0 and "" or (tostring(pending_total) .. " pending · " .. tostring(#rows) .. " shown"))
    local detail = state.detail
    local selected = model.selected_row(state)
    local detail_rows = 0
    local permission_lines: {string} = {}
    local asked_lines: {string} = {}
    if detail and selected and detail.approval_id == selected.approval_id and height >= 12 then
        permission_lines = model.permission_lines(detail)
        asked_lines = prompt_lines(selected.prompt, width)
        local needed = 4 + #asked_lines + #permission_lines
        if state.technical then needed = needed + 2 + #model.payload_lines(detail) end
        detail_rows = math.floor(math.max(6, math.min(height - 5, needed)))
    end
    local list_first = 3
    local list_last = height - 3 - detail_rows
    local selected_index = 0
    if selected then
        for index, row in ipairs(rows) do if row.approval_id == selected.approval_id then selected_index = index end end
    end
    local window = frame.window(#rows, list_last - list_first + 1, selected_index, offset)
    if #rows == 0 and list_last >= list_first then
        frame.empty(painter, list_first, "No decisions needed", list_last > list_first and "Requests that need your decision appear here · R refresh" or nil)
    end
    for slot = 1, window.capacity do
        local row = rows[window.offset + slot]
        if not row then break end
        local label = string.format("%s%-9s %s %s", slice.marked[row.approval_id] and "[x] " or "", state_label(row), row.effect, model.text(row.prompt, 256))
        if width >= 60 then
            local workspace = locations[row.workspace_id]
            label = label .. " · " .. (workspace and (workspace.label .. " / " .. workspace.folder) or "Workspace unavailable")
        end
        frame.row(painter, list_first + slot - 1, label, window.offset + slot == selected_index, "row", window.offset + slot, row.approval_id)
    end
    if detail and selected and detail_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        local lines: {string} = {
            "Effect: " .. selected.effect,
        }
        for _, asked_line in ipairs(asked_lines) do lines[#lines + 1] = asked_line end
        for _, permission_line in ipairs(permission_lines) do
            lines[#lines + 1] = permission_line
        end
        if detail.requesting_session then lines[#lines + 1] = "Source: Session · S returns to the conversation" end
        lines[#lines + 1] = "State: " .. state_label(selected) .. (selected.decider_id and (" by " .. selected.decider_id) or "") .. "  expires " .. selected.expires_at
        if state.technical then
            lines[#lines + 1] = "Requester: " .. selected.requester_id .. " · Owner: " .. selected.owner_node .. " · Policy: " .. selected.policy
            lines[#lines + 1] = "Target: " .. selected.target
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
        local buttons: {frame.Button} = {}
        if can_open then buttons[#buttons + 1] = {kind = "open", key = "Enter", label = "Open", enabled = true, primary = true} end
        if pending_detail then
            buttons[#buttons + 1] = {kind = "approve", key = "A", label = "Allow once", enabled = idle, primary = true}
            if model.window_cap(state) >= 1800000 then buttons[#buttons + 1] = {kind = "allow_30", key = "F", label = detail.reallow and "Re-allow 30 min" or "Allow 30 min", enabled = idle} end
            if model.window_cap(state) > 1800000 then buttons[#buttons + 1] = {kind = "allow_longer", key = "L", label = "Allow longer", enabled = idle} end
            buttons[#buttons + 1] = {kind = "deny", key = "D", label = "Deny", enabled = idle}
            buttons[#buttons + 1] = {kind = "withdraw", key = "W", label = "Withdraw", enabled = idle, more = true}
        end
        buttons[#buttons + 1] = {kind = "refresh", key = "R", label = "Refresh", enabled = idle, primary = #rows == 0, more = #rows > 0}
        if detail then
            buttons[#buttons + 1] = {kind = "source", key = "S", label = "Return to source", enabled = detail.requesting_session ~= nil, more = true}
            buttons[#buttons + 1] = {kind = "technical", key = "T", label = state.technical and "Hide details" or "Details", enabled = true, more = true}
        end
        if selected and selected.state == "pending" then buttons[#buttons + 1] = {kind = "mark", key = "M", label = "Mark", enabled = true, more = true} end
        if marked > 0 then
            buttons[#buttons + 1] = {kind = "batch_approve", key = "B", label = "Approve " .. tostring(marked), enabled = idle, more = true}
            buttons[#buttons + 1] = {kind = "batch_deny", key = "N", label = "Deny " .. tostring(marked), enabled = idle, more = true}
        end
        if can_lease then buttons[#buttons + 1] = {kind = "lease", key = "E", label = "Lease", enabled = idle, more = true} end
        if can_grant then buttons[#buttons + 1] = {kind = "grant", key = "G", label = "Grant", enabled = idle, more = true} end
        buttons[#buttons + 1] = {kind = "windows", key = "U", label = "Your grants", enabled = true, more = true}
        buttons[#buttons + 1] = {kind = "leases", key = "V", label = "Leases", enabled = true, more = true}
        frame.actions(painter, height - 1, buttons)
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" then message = slice.notice end
    if message == "" and state.pending then message = "Waiting for the approval owner…" end
    for _, workspace in ipairs(state.workspaces) do
        local unavailable = state.unavailable[workspace]
        if message == "" and unavailable then
            local label = names.label(workspace)
            if state.technical then label = label .. " (" .. workspace .. ")" end
            message = "Workspace " .. label .. " unavailable: " .. unavailable
        end
    end
    if height >= 6 then frame.line(painter, height - 2, message, theme.text) end
    frame.footer(painter, "", #rows == 0 and frame.hints({{key = "R", verb = "refresh"}}) or HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = window.capacity, offset = window.offset}
end
return M

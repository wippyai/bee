-- MIT. The inbox frame: rows of requests, the selected request's proposed
-- effect first with technical details behind a toggle, explicit actions
-- and the status line. Every text comes through the model's bounding; the
-- view interprets nothing.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
type Hit = {kind: string, index: integer, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer}
local M = {}
local RESET = "\27[0m"
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do
        if x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then return hit end
    end
    return nil
end
local function state_label(row: model.Row): string
    if row.state == "decided" then return row.decision or "decided" end
    return row.state
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, rows: {model.Row}, offset: integer, status: string): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, text: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and x >= 1 and size > 0 then
            canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. text .. RESET, size)
        end
    end
    local function line(y: integer, text: string, fg: string?, bg: string?)
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, tty.text.truncate(text, maximum(0, width - 2), "…"), maximum(0, width - 2), fg, bg)
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(1, "APPROVALS", theme.text, theme.surface)
    local detail = state.detail
    local selected = model.selected_row(state)
    local detail_rows = 0
    if detail and selected and detail.approval_id == selected.approval_id and height >= 12 then
        detail_rows = math.floor(math.max(6, math.min(height - 8, state.technical and 14 or 8)))
    end
    local list_first = 3
    local list_last = height - 2 - detail_rows
    local capacity = maximum(0, list_last - list_first + 1)
    local last = maximum(0, #rows - capacity)
    local next_offset = math.floor(math.max(0, math.min(last, offset)))
    if selected then
        for index, row in ipairs(rows) do
            if row.approval_id == selected.approval_id then
                if index <= next_offset then next_offset = index - 1 end
                if index > next_offset + capacity then next_offset = index - capacity end
            end
        end
    end
    if #rows == 0 then
        line(list_first, "No requests", theme.muted)
    end
    for slot = 1, capacity do
        local row = rows[next_offset + slot]
        if not row then break end
        local y = list_first + slot - 1
        local active = selected ~= nil and row.approval_id == selected.approval_id
        local fg, bg = active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface
        local label = string.format("%-9s %s %s", state_label(row), row.effect, row.target)
        if width >= 60 then label = label .. "  from " .. row.requester_id .. "  until " .. row.expires_at end
        line(y, label, fg, bg)
        hits[#hits + 1] = {kind = "row", index = next_offset + slot, x = 1, y = y, width = width, height = 1}
    end
    if detail and selected and detail_rows > 0 then
        local y = list_last + 1
        put(1, y, string.rep("─", width), width, theme.border)
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
        for index, text in ipairs(lines) do
            if index > detail_rows - 1 then break end
            line(y + index, text, theme.text)
        end
    end
    local footer = height
    local actions_y = height - 1
    local x = 2
    local function button(kind: string, label: string, enabled: boolean)
        local size = tty.text.width(label)
        if x + size > width then return end
        put(x, actions_y, label, size, enabled and appearance.selection_text(theme) or theme.muted, enabled and theme.accent or theme.surface)
        if enabled then hits[#hits + 1] = {kind = kind, index = 0, x = x, y = actions_y, width = size, height = 1} end
        x = x + size + 1
    end
    local pending_detail = detail ~= nil and selected ~= nil and detail.approval_id == selected.approval_id and detail.state == "pending"
    local idle = state.pending == nil
    if height >= 4 then
        button("open", " Open ", selected ~= nil and detail == nil)
        button("approve", " Approve ", pending_detail and idle)
        button("deny", " Deny ", pending_detail and idle)
        button("withdraw", " Withdraw ", pending_detail and idle)
        button("refresh", " Refresh ", idle)
        button("technical", state.technical and " Less " or " Details ", detail ~= nil)
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" and state.pending then message = "Waiting for the approval owner…" end
    for _, workspace in ipairs(state.workspaces) do
        local unavailable = state.unavailable[workspace]
        if message == "" and unavailable then message = "Workspace " .. workspace .. " unavailable: " .. unavailable end
    end
    line(footer, message, theme.muted)
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
end
return M

-- MIT. Local destination plan and activation status, with review evidence
-- separated from the decision displayed in the existing Approvals inbox.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local text = require("text")

local M = {}
local RESET = "\27[0m"
type Frame = {rows: {string}, capacity: integer, offset: integer}
local function maximum(a: integer, b: integer): integer
    if a > b then return a end
    return b
end
local function clipped(value: string, limit: integer): string
    return tty.text.truncate(value, maximum(0, limit), "…")
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    state: model.State, offset: integer): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and x >= 1 and size > 0 then
            canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. value .. RESET, size)
        end
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        if y < 1 or y > height then return end
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, clipped(text.bound(value, 8192), maximum(0, width - 2)), maximum(0, width - 2), fg, bg)
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(1, "APP DELIVERY", theme.text, theme.surface)
    local workspace_label = state.workspace_id
    if #workspace_label > 20 then workspace_label = workspace_label:sub(1, 10) .. "…" .. workspace_label:sub(-6) end
    local pane_label = "STAGED PLANS"
    if state.pane == "available" then pane_label = "AVAILABLE"
    elseif state.pane == "review" then pane_label = "REVIEW" end
    line(2, "Destination workspace " .. workspace_label .. "   " .. pane_label, theme.muted)
    local status_y = height - 2
    if state.pane == "review" then
        local review = model.review_rows(state)
        put(1, 3, string.rep("─", width), width, theme.border)
        local first = 4
        local room = maximum(0, status_y - 1 - first + 1)
        local last = maximum(0, #review - room)
        local start = math.floor(math.max(0, math.min(last, offset)))
        for slot = 1, room do
            local row = review[start + slot]
            if not row then break end
            line(first + slot - 1, row.text, row.heading and theme.muted or theme.text)
        end
        local status = state.notice
        if status == "" then status = "Approval decisions are made in Approvals" end
        line(status_y, status, theme.muted)
        line(height - 1, "Tab Available   ↑↓ Scroll   Enter Read   A Accept   S Select   P Prepare   T Details", theme.muted)
        line(height, "X Step   I Status   G Recover   F Refresh   Esc Close", theme.muted)
        return {rows = canvas:rows(), capacity = room, offset = start}
    end
    local plans_pane = state.pane == "plans"
    if plans_pane then
        line(3, string.format("%-24s %-12s %-14s %-9s %s", "SOURCE", "VERSION", "STATE", "REVIEW", "SELECTED"), theme.muted)
    else
        line(3, string.format("%-24s %-20s %-12s %s", "APPLICATION", "SOURCE", "VERSION", "STATE"), theme.muted)
    end

    local selected = plans_pane and model.selected(state) or nil
    local selected_available = not plans_pane and model.selected_available(state) or nil
    local has_selection = selected ~= nil or selected_available ~= nil
    local detail_rows = has_selection and height >= 13 and math.floor(math.max(5, math.min(height - 9, state.technical and 9 or 6))) or 0
    local list_first = 4
    local list_last = status_y - 1 - detail_rows
    local capacity = maximum(0, list_last - list_first + 1)
    local count = plans_pane and #state.plans or #state.available
    local last_offset = maximum(0, count - capacity)
    local next_offset = math.floor(math.max(0, math.min(last_offset, offset)))
    if selected or selected_available then
        for index = 1, count do
            local matches = false
            if plans_pane and selected then matches = model.key(state.plans[index]) == model.key(selected)
            elseif selected_available then matches = model.available_key(state.available[index]) == model.available_key(selected_available) end
            if matches then
                if index <= next_offset then next_offset = index - 1 end
                if index > next_offset + capacity then next_offset = index - capacity end
                break
            end
        end
    end
    if count == 0 then
        line(list_first, plans_pane and "No staged application versions" or "No available application versions", theme.muted)
    end
    for slot = 1, capacity do
        local index = next_offset + slot
        if plans_pane then
            local item = state.plans[index]
            if not item then break end
            local active = selected ~= nil and model.key(item) == model.key(selected)
            local fg = active and appearance.selection_text(theme) or theme.text
            local bg = active and theme.accent or theme.surface
            local review = item.review_status or "pending"
            local selected_text = item.selected and "yes" or "no"
            local label = string.format("%-24s %-12s %-14s %-9s %s", clipped(item.source_workspace, 24),
                clipped(item.version, 12), item.status, review, selected_text)
            line(list_first + slot - 1, label, fg, bg)
        else
            local item = state.available[index]
            if not item then break end
            local active = selected_available ~= nil and model.available_key(item) == model.available_key(selected_available)
            local fg = active and appearance.selection_text(theme) or theme.text
            local bg = active and theme.accent or theme.surface
            local status = model.available_status(state, item)
            local label = string.format("%-24s %-20s %-12s %s", clipped(item.component, 24),
                clipped(item.source_workspace, 20), clipped(item.version, 12), status)
            line(list_first + slot - 1, label, fg, bg)
        end
    end

    if has_selection and detail_rows > 0 then
        local y = list_last + 1
        put(1, y, string.rep("─", width), width, theme.border)
        local rows: {string} = {}
        if selected_available then
            rows = {"Application " .. selected_available.component .. "  version " .. selected_available.version,
                "Source " .. selected_available.owner_id .. "  workspace " .. selected_available.source_workspace,
                "Content " .. tostring(selected_available.total_bytes) .. " bytes  state " .. model.available_status(state, selected_available),
                "Stage creates a local review plan; it does not install or activate this version."}
            if state.technical then rows[#rows + 1] = "Descriptor " .. selected_available.descriptor_digest end
        elseif selected then
            rows = {"Source node " .. selected.source_node .. "  workspace " .. selected.source_workspace,
                "Version " .. selected.version .. "  plan " .. selected.status .. "  review " .. (selected.review_status or "pending")
                    .. "  revision " .. tostring(selected.revision) .. (selected.selected and "  selected" or "")}
            if state.technical then
                rows[#rows + 1] = "Plan " .. selected.plan_digest
                rows[#rows + 1] = "Artifact " .. selected.artifact_digest .. "  preflight " .. selected.preflight_digest
                if selected.review_reason and selected.review_reason ~= "" then rows[#rows + 1] = "Review: " .. text.bound(selected.review_reason, 512) end
            end
            if state.intent then
                rows[#rows + 1] = "Activation " .. state.intent.intent_id .. "  " .. state.intent.phase
                    .. (state.intent.outcome and ("  " .. state.intent.outcome) or "")
                if state.intent.diagnostics and state.intent.diagnostics ~= "" then rows[#rows + 1] = "Result: " .. text.bound(state.intent.diagnostics, 8192) end
            end
            rows[#rows + 1] = "Preparation requests approval; decide it in the Approvals inbox before Step."
        end
        for index, value in ipairs(rows) do
            if index > detail_rows - 1 then break end
            line(y + index, value, index == 1 and theme.muted or theme.text)
        end
    end
    local status = state.notice
    if status == "" then status = "Approval decisions are made in Approvals" end
    line(status_y, status, theme.muted)
    if plans_pane then
        line(height - 1, "Tab Review   ↑↓ Choose   Enter Get   A Accept   N Reject   S Select   P Prepare", theme.muted)
        line(height, "X Step   I Status   G Recover   F Refresh   T Details   Esc Close", theme.muted)
    else
        line(height - 1, "Tab Staged plans   ↑↓ Choose   S Stage   Enter Stage   F Refresh   T Details", theme.muted)
        line(height, "Stage makes a local review plan only   Esc Close", theme.muted)
    end
    return {rows = canvas:rows(), capacity = capacity, offset = next_offset}
end
return M

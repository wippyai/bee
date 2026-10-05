-- MIT. Local destination plan and activation status. The view keeps review,
-- approval and activation distinct while making the next local action obvious.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local text = require("text")

type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer}
type Action = {kind: string, label: string}
local M = {}
local PANES: {frame.Tab} = {{kind = "pane_available", label = "Available", short = "A"},
    {kind = "pane_plans", label = "Staged", short = "S"}, {kind = "pane_review", label = "Review", short = "R"}}
local HINTS = frame.hints({{key = "Tab", verb = "view"}, {key = "↑↓", verb = "choose"}, {key = "Enter", verb = "next"},
    {key = "T", verb = "details"}, {key = "R", verb = "refresh"}, {key = "Esc", verb = "close"}})
local TECHNICAL_HINTS = frame.hints({{key = "N", verb = "reject"}, {key = "I", verb = "status"}, {key = "G", verb = "recover"},
    {key = "X", verb = "apply"}, {key = "A", verb = "accept"}, {key = "S", verb = "select"}, {key = "P", verb = "prepare"}})

-- Button labels here carry their padding; the frame adds its own.
local function bare(label: string): string
    local value = label:match("^%s*(.-)%s*$")
    return value or label
end

-- The pane a tab hit selects, or nil for any other hit kind.
function M.pane_of(kind: string): model.Pane?
    if kind == "pane_available" then return "available" end
    if kind == "pane_plans" then return "plans" end
    if kind == "pane_review" then return "review" end
    return nil
end

-- The primary action prepares activation after the local review and selection
-- transitions, then applies it; applying waits for the approval owner's
-- decision, which the person gives in the Inbox.
function M.primary(state: model.State): (string, string, boolean)
    if state.pane == "available" then return "stage", " Stage ", model.selected_available(state) ~= nil end
    local item = model.selected(state)
    if state.pane == "plans" then return "read", " Read review ", item ~= nil end
    if not item then return "read", " Read review ", false end
    local verdict = model.verdict(state, item)
    if verdict == "unread" or verdict == "unreadable" then return "read", " Read review ", true end
    local intent = state.intent
    if intent and model.key(item) == (intent.source_node .. "\0" .. intent.source_workspace .. "\0" .. intent.version) then
        if intent.phase == "settled" then return "read", " Read details ", true end
        if model.can_advance(state) then return "step", " Apply ", true end
        return "status", " Check status ", true
    end
    if verdict == "ready" and (model.accepts_review(item) or model.can_select(item)) then
        return "prepare_activation", " Prepare activation ", true
    end
    return "read", " Read details ", true
end

local function advanced(state: model.State): {Action}
    local actions: {Action} = {}
    local item = model.selected(state)
    if state.pane ~= "available" and item and model.accepts_review(item) then actions[#actions + 1] = {kind = "reject", label = " Reject "} end
    if state.intent then
        actions[#actions + 1] = {kind = "status", label = " Status "}
        actions[#actions + 1] = {kind = "recover", label = " Recover "}
        if model.can_advance(state) then actions[#actions + 1] = {kind = "step", label = " Apply "} end
    end
    return actions
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    state: model.State, offset: integer): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local function selected_summary(): string
        if state.pane == "available" then
            local item = model.selected_available(state)
            if not item then return "" end
            return item.component .. " · " .. item.version .. " · " .. model.available_status(state, item)
        end
        local item = model.selected(state)
        if not item then return "" end
        return item.source_workspace .. " · " .. item.version .. " · " .. item.status .. " · " .. (item.review_status or "review pending")
    end
    local function selected_rows(): {string}
        local rows: {string} = {}
        if state.pane == "available" then
            local item = model.selected_available(state)
            if item then
                rows = {"Source " .. item.source_workspace .. " · " .. item.owner_id,
                    "Staging creates a local review plan. It does not install or activate this version."}
                if state.technical then rows[#rows + 1] = "Descriptor " .. item.descriptor_digest end
            end
            return rows
        end
        local item = model.selected(state)
        if not item then return rows end
        rows = {"Destination review is local. Approval is decided separately by the node's approval owner."}
        if state.pane == "review" then rows[#rows + 1] = "Preflight " .. model.verdict(state, item) .. " · review " .. (item.review_status or "pending") end
        if state.technical then
            rows[#rows + 1] = "Plan " .. item.plan_digest
            rows[#rows + 1] = "Artifact " .. item.artifact_digest
            if item.review_reason and item.review_reason ~= "" then rows[#rows + 1] = "Review " .. item.review_reason end
        end
        if state.intent then
            rows[#rows + 1] = "Activation " .. state.intent.phase .. (state.intent.outcome and (" · " .. state.intent.outcome) or "")
            if state.intent.diagnostics and state.intent.diagnostics ~= "" then rows[#rows + 1] = state.intent.diagnostics end
        end
        return rows
    end

    frame.header(painter, "OVERLAYS", tostring(#state.available) .. " available · " .. tostring(#state.plans) .. " staged")
    if height >= 2 then frame.tabs(painter, 2, PANES, "pane_" .. state.pane) end

    local status_y = height - 1
    -- Row 4 heads the pane's list, after the blank row under the tabs.
    local heading_y = 4
    local list_first = 5
    local selected = state.pane == "available" and model.selected_available(state) or model.selected(state)
    -- The selected version's section: its heading, its summary line and its rows.
    local detail_rows: integer = 0
    if selected and height >= 14 then detail_rows = state.technical and 6 or 4 end
    local list_last = status_y - detail_rows - (detail_rows > 0 and 2 or 1)
    local capacity = math.floor(math.max(0, list_last - list_first + 1))
    local count = state.pane == "available" and #state.available or (state.pane == "plans" and #state.plans or 0)
    local next_offset = math.floor(math.max(0, math.min(math.max(0, count - capacity), offset)))
    if state.pane ~= "review" and height >= 6 then
        local summary = ""
        if count > 0 then summary = tostring(count) .. (count == 1 and " version" or " versions") .. (selected and "" or " · choose one") end
        frame.section(painter, heading_y, state.pane == "available" and "Available versions" or "Staged versions", summary)
    end
    if state.pane == "review" then
        -- Review sections, a gap before each but the first, their rows indented.
        local laid: {{text: string, heading: boolean, summary: string?}} = {}
        for index, row in ipairs(model.review_rows(state)) do
            if row.heading and index > 1 then laid[#laid + 1] = {text = "", heading = false} end
            laid[#laid + 1] = {text = row.text, heading = row.heading, summary = row.summary}
        end
        local review_first = heading_y
        local room = math.floor(math.max(0, list_last - review_first + 1))
        local last = math.floor(math.max(0, #laid - room))
        next_offset = math.floor(math.max(0, math.min(last, offset)))
        for slot = 1, room do
            local row = laid[next_offset + slot]
            if not row then break end
            local y = review_first + slot - 1
            if row.heading then frame.section(painter, y, text.bound(row.text, 8192), row.summary and text.bound(row.summary, 8192) or nil)
            elseif row.text ~= "" then frame.line(painter, y, "  " .. text.bound(row.text, 8192), theme.text) end
        end
        capacity = room
    else
        if count == 0 and capacity > 0 then
            if state.pane == "available" then
                frame.empty(painter, list_first, "No overlay versions are available",
                    capacity > 1 and "Versions an agent delivers to this workspace appear here · R refresh" or nil)
            else
                frame.empty(painter, list_first, "No overlay versions are staged",
                    capacity > 1 and "Stage one from Available · Tab change view" or nil)
            end
        end
        -- Wide rows align their fields in columns; narrow rows join them with " · ".
        local function columns(first: string, second: string, third: string, fourth: string): string
            if width < 62 then return first .. " · " .. second .. " · " .. third .. " · " .. fourth end
            local name = math.floor(math.max(12, math.min(32, width - 52)))
            return frame.pad(first, name) .. "  " .. frame.pad(second, 12) .. "  " .. frame.pad(third, 12) .. "  " .. fourth
        end
        for slot = 1, capacity do
            local index, y = next_offset + slot, list_first + slot - 1
            if state.pane == "available" then
                local item = state.available[index]
                if not item then break end
                local chosen = model.selected_available(state)
                local active = chosen ~= nil and model.available_key(item) == model.available_key(chosen)
                local label = columns(item.component, item.version, model.available_status(state, item), "from " .. item.source_workspace)
                frame.row(painter, y, text.bound(label, 8192), active, "available", index, model.available_key(item))
            else
                local item = state.plans[index]
                if not item then break end
                local chosen = model.selected(state)
                local active = chosen ~= nil and model.key(item) == model.key(chosen)
                local label = columns(item.source_workspace, item.version, item.status, item.review_status or "review pending")
                frame.row(painter, y, text.bound(label, 8192), active, "plan", index, model.key(item))
            end
        end
    end
    if selected and detail_rows > 0 then
        local first = status_y - detail_rows
        frame.section(painter, first, "Selected")
        frame.line(painter, first + 1, "  " .. text.bound(selected_summary(), 8192), theme.text)
        for index, row in ipairs(selected_rows()) do
            if index + 1 >= detail_rows then break end
            frame.line(painter, first + 1 + index, "  " .. text.bound(row, 8192), index == 1 and theme.muted or theme.text)
        end
    end
    if height >= 4 then
        local primary_kind, primary_label, primary_enabled = M.primary(state)
        local buttons: {frame.Button} = {{kind = primary_kind, key = "Enter", label = bare(primary_label), enabled = primary_enabled, primary = true},
            {kind = "details", key = "T", label = state.technical and "Hide details" or "Details", enabled = true}}
        if state.technical then
            for _, action in ipairs(advanced(state)) do
                buttons[#buttons + 1] = {kind = action.kind, label = bare(action.label), enabled = true}
            end
        end
        frame.actions(painter, status_y, buttons)
    end
    local status = state.notice
    if status == "" and state.intent and state.intent.phase == "approval_bound" then status = "Waiting for the approval decision" end
    frame.footer(painter, text.bound(status, 8192), HINTS, TECHNICAL_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset}
end

return M

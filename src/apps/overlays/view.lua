-- MIT. Local destination plan and activation status. The view keeps review,
-- approval and activation distinct while making the next local action obvious.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local text = require("text")

type Hit = {kind: string, key: string, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer}
type Action = {kind: string, label: string}
local M = {}
local RESET = "\27[0m"

local function maximum(a: integer, b: integer): integer
    if a > b then return a end
    return b
end

local function clipped(value: string, limit: integer): string
    return tty.text.truncate(text.bound(value, 8192), maximum(0, limit), "…")
end

function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do
        if x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then return hit end
    end
    return nil
end

-- The primary action is deliberately one local transition. An approval is
-- never represented as an apply button: it remains a separate decision in
-- Approvals, and activation can proceed only after that owner binds it.
function M.primary(state: model.State): (string, string, boolean)
    if state.pane == "available" then return "stage", " Stage ", model.selected_available(state) ~= nil end
    local item = model.selected(state)
    if state.pane == "plans" then return "read", " Read review ", item ~= nil end
    if not item then return "read", " Read review ", false end
    local verdict = model.verdict(state, item)
    if verdict == "unread" or verdict == "unreadable" then return "read", " Read review ", true end
    if model.accepts_review(item) then
        if verdict == "ready" then return "accept", " Accept review ", true end
        return "read", " Read details ", true
    end
    if model.can_select(item) and not item.selected then return "select", " Select version ", true end
    if model.can_prepare(state, item) then return "prepare", " Request approval ", true end
    local intent = state.intent
    if intent and model.key(item) == (intent.source_node .. "\0" .. intent.source_workspace .. "\0" .. intent.version) then
        if intent.phase == "authorized" or intent.phase == "applying" then return "step", " Apply approved ", true end
        return "status", " Check status ", true
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
        if state.intent.phase == "authorized" or state.intent.phase == "applying" then actions[#actions + 1] = {kind = "step", label = " Apply "} end
    end
    return actions
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences,
    state: model.State, offset: integer): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and x >= 1 and x <= width and size > 0 then
            local room = math.floor(math.min(size, width - x + 1))
            if room > 0 then canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. clipped(value, room) .. RESET, room) end
        end
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        if y < 1 or y > height then return end
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, value, maximum(0, width - 2), fg, bg)
    end
    local function rule(y: integer) put(1, y, string.rep("─", width), width, theme.border) end
    local function button(kind: string, label: string, x: integer, y: integer, primary: boolean): integer
        local size = tty.text.width(label)
        if x < 1 or x + size - 1 > width or y < 1 or y > height then return x end
        put(x, y, label, size, primary and appearance.selection_text(theme) or theme.text, primary and theme.accent or theme.surface)
        hits[#hits + 1] = {kind = kind, key = "", x = x, y = y, width = size, height = 1}
        return x + size + 1
    end
    local function selected_summary(): string
        if state.pane == "available" then
            local item = model.selected_available(state)
            if not item then return "Choose an overlay version" end
            return item.component .. " · " .. item.version .. " · " .. model.available_status(state, item)
        end
        local item = model.selected(state)
        if not item then return "Choose a staged version" end
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
        rows = {"Destination review is local. Approval is decided separately in Approvals."}
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

    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    line(1, "OVERLAYS", theme.text)
    if height >= 2 then
        local x = 2
        for _, pane in ipairs({"available", "plans", "review"}) do
            local label = width < 34 and (" " .. pane:sub(1, 1):upper() .. " ") or (pane == "available" and " Available " or pane == "plans" and " Staged " or " Review ")
            local size = tty.text.width(label)
            if x + size - 1 <= width then
                local active = pane == state.pane
                put(x, 2, label, size, active and appearance.selection_text(theme) or theme.muted, active and theme.accent or theme.surface)
                hits[#hits + 1] = {kind = "pane", key = pane, x = x, y = 2, width = size, height = 1}
                x = x + size + 1
            end
        end
    end

    local primary_kind, primary_label, primary_enabled = M.primary(state)
    local action_y = 3
    if height >= action_y then
        local right = width - tty.text.width(primary_label) + 1
        if primary_enabled and right >= 2 then button(primary_kind, primary_label, right, action_y, true) end
        local details_label = state.technical and " Less " or " Details "
        local details_x = right - tty.text.width(details_label) - 1
        if details_x >= 2 then button("details", details_label, details_x, action_y, false) end
        if state.technical then
            local next_x = 2
            for _, action in ipairs(advanced(state)) do
                local label = action.label
                if next_x + tty.text.width(label) >= details_x then break end
                next_x = button(action.kind, label, next_x, action_y, false)
            end
        end
        local summary_room = maximum(0, (state.technical and 2 or details_x) - 3)
        if summary_room > 0 then put(2, action_y, selected_summary(), summary_room, theme.muted) end
    end

    local status_y, footer_y = height - 1, height
    local list_first = 4
    local selected = state.pane == "available" and model.selected_available(state) or model.selected(state)
    local detail_rows: integer = 0
    if selected and height >= 14 then detail_rows = state.technical and 5 or 3 end
    local list_last = status_y - detail_rows - 1
    local capacity = maximum(0, list_last - list_first + 1)
    local count = state.pane == "available" and #state.available or (state.pane == "plans" and #state.plans or 0)
    local next_offset = math.floor(math.max(0, math.min(maximum(0, count - capacity), offset)))
    if state.pane == "review" then
        local review = model.review_rows(state)
        local room = maximum(0, status_y - list_first)
        local last = maximum(0, #review - room)
        next_offset = math.floor(math.max(0, math.min(last, offset)))
        for slot = 1, room do
            local row = review[next_offset + slot]
            if not row then break end
            line(list_first + slot - 1, row.text, row.heading and theme.muted or theme.text)
        end
        capacity = room
    else
        if count == 0 and capacity > 0 then line(list_first, state.pane == "available" and "No overlay versions are available" or "No overlay versions are staged", theme.muted) end
        for slot = 1, capacity do
            local index, y = next_offset + slot, list_first + slot - 1
            if state.pane == "available" then
                local item = state.available[index]
                if not item then break end
                local chosen = model.selected_available(state)
                local active = chosen ~= nil and model.available_key(item) == model.available_key(chosen)
                local label = width < 62 and (item.component .. " · " .. item.version .. " · " .. model.available_status(state, item))
                    or (item.component .. "  " .. item.version .. "  " .. model.available_status(state, item) .. "  from " .. item.source_workspace)
                line(y, label, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
                hits[#hits + 1] = {kind = "available", key = model.available_key(item), x = 1, y = y, width = width, height = 1}
            else
                local item = state.plans[index]
                if not item then break end
                local chosen = model.selected(state)
                local active = chosen ~= nil and model.key(item) == model.key(chosen)
                local review = item.review_status or "review pending"
                local label = width < 62 and (item.source_workspace .. " · " .. item.version .. " · " .. item.status .. " · " .. review)
                    or (item.source_workspace .. "  " .. item.version .. "  " .. item.status .. "  " .. review)
                line(y, label, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
                hits[#hits + 1] = {kind = "plan", key = model.key(item), x = 1, y = y, width = width, height = 1}
            end
        end
    end
    if selected and detail_rows > 0 then
        local first = status_y - detail_rows
        rule(first)
        for index, row in ipairs(selected_rows()) do
            if index >= detail_rows then break end
            line(first + index, row, index == 1 and theme.muted or theme.text)
        end
    end
    local status = state.notice
    if status == "" then
        if state.intent and state.intent.phase == "approval_bound" then status = "Waiting for the approval decision in Approvals"
        else status = "Choose a version and take the highlighted next action" end
    end
    line(status_y, status, theme.muted)
    local help = state.technical and "Details: N reject · I status · G recover · X apply · Enter next action"
        or "Tab change view · ↑↓ choose · Enter next action · T details · F refresh · Esc close"
    line(footer_y, help, theme.muted)
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
end

return M

-- MIT. Modules renders model state only. Hit rectangles become application
-- events; this frame neither opens Hub nor confirms an install.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local M = {}
local RESET = "\27[0m"
type Hit = {kind: string, key: string, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do if x >= hit.x and y >= hit.y and x < hit.x + hit.width and y < hit.y + hit.height then return hit end end
    return nil
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local theme, canvas = appearance.theme(preferences.theme), tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if x >= 1 and y >= 1 and y <= height and size > 0 then canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. value .. RESET, size) end
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, tty.text.truncate(value, maximum(0, width - 2), "…"), maximum(0, width - 2), fg, bg)
    end
    local function button(x: integer, y: integer, kind: string, label: string, enabled: boolean): integer
        local size = tty.text.width(label)
        if x + size > width or y < 1 or y > height then return x end
        put(x, y, label, size, enabled and appearance.selection_text(theme) or theme.muted, enabled and theme.accent or theme.surface)
        if enabled then hits[#hits + 1] = {kind = kind, key = "", x = x, y = y, width = size, height = 1} end
        return x + size + 1
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    local phase = string.upper(state.phase)
    line(1, "MODULES  " .. phase, theme.text)
    if width >= 54 then
        local selected = state.selected or "Browse the Hub"
        local span = tty.text.width(selected)
        put(math.floor(math.max(2, width - span)), 1, selected, span, theme.accent)
    end
    local x = 2
    x = button(x, 2, "catalog", " Catalog ", true)
    x = button(x, 2, "installed", " Installed ", true)
    x = button(x, 2, "details", " Details ", state.selected ~= nil)
    x = button(x, 2, "plan", " Plan ", state.selected ~= nil)
    if state.phase == "catalog" then
        local filters = "Keyword: " .. (state.keyword == "" and "all" or state.keyword) .. "  Search: " .. (state.query == "" and "(none)" or state.query)
        if width < 56 then filters = "Keyword " .. (state.keyword == "" and "all" or state.keyword) end
        line(3, filters, theme.muted)
        local first, last = 4, height - 2
        local capacity = maximum(0, last - first + 1)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.catalog - capacity), offset)))
        if #state.catalog == 0 then line(first, "No packages on this page", theme.muted) end
        for slot = 1, capacity do
            local item = state.catalog[next_offset + slot]
            if not item then break end
            local y, selected = first + slot - 1, item.component == state.selected
            local label = item.title ~= "" and item.title or item.component
            if width >= 58 then label = label .. "  " .. item.component .. "  " .. item.latest_version .. "  " .. item.description
            elseif width >= 32 then label = label .. "  " .. item.latest_version end
            line(y, label, selected and appearance.selection_text(theme) or theme.text, selected and theme.accent or theme.surface)
            hits[#hits + 1] = {kind = "component", key = item.component, x = 1, y = y, width = width, height = 1}
        end
        local actions = 2
        actions = button(actions, height - 1, "previous", " Prev ", state.page > 1)
        actions = button(actions, height - 1, "next", " Next ", #state.catalog > 0 and state.total > state.page * #state.catalog)
        line(height, status ~= "" and status or "Type / to search · K changes keyword · Enter details · ←/→ page", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
    end
    if state.phase == "installed" then
        line(3, "Installed roots and their measured closure", theme.muted)
        local first, last = 4, height - 2
        local capacity = maximum(0, last - first + 1)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.installed - capacity), offset)))
        if #state.installed == 0 then line(first, "No installed Hub modules", theme.muted) end
        for slot = 1, capacity do
            local item = state.installed[next_offset + slot]
            if not item then break end
            local y, selected = first + slot - 1, item.component == state.selected
            local label = (item.direct and "root " or "     ") .. item.component .. "  " .. item.version
            if width >= 68 and #item.used_by > 0 then label = label .. "  used by " .. table.concat(item.used_by, ", ") end
            line(y, label, selected and appearance.selection_text(theme) or theme.text, selected and theme.accent or theme.surface)
            hits[#hits + 1] = {kind = "component", key = item.component, x = 1, y = y, width = width, height = 1}
        end
        button(2, height - 1, "refresh", " Refresh ", true)
        line(height, status ~= "" and status or "↑↓ select · Enter details · R refresh", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
    end
    local detail = state.detail
    if state.phase == "details" or not state.plan then
        line(3, detail and (detail.title .. "  " .. detail.component) or "Select a package to read its details", theme.muted)
        if detail then
            line(4, detail.description, theme.text)
            local first, last = 6, height - 4
            local capacity = maximum(0, last - first + 1)
            local next_offset = math.floor(math.max(0, math.min(maximum(0, #detail.versions - capacity), offset)))
            for slot = 1, capacity do
                local item = detail.versions[next_offset + slot]
                if not item then break end
                local y, selected = first + slot - 1, item.version == state.selected_version
                local label = item.version .. (item.yanked and "  yanked" or "")
                line(y, label, selected and appearance.selection_text(theme) or (item.yanked and theme.muted or theme.text), selected and theme.accent or theme.surface)
                hits[#hits + 1] = {kind = "version", key = item.version, x = 1, y = y, width = width, height = 1}
            end
            local actions = 2
            actions = button(actions, height - 2, "install", " Install ", true)
            actions = button(actions, height - 2, "update", " Update ", true)
            actions = button(actions, height - 2, "uninstall", " Remove ", true)
            actions = button(actions, height - 2, "plan", " Prepare ", state.selected_version ~= nil or state.action == "uninstall")
            local policy_x = 2
            policy_x = button(policy_x, height - 1, "parameter", " JSON value ", state.action ~= "uninstall")
            if state.action == "uninstall" then
                policy_x = button(policy_x, height - 1, "policy_block", " Block ", true)
                policy_x = button(policy_x, height - 1, "policy_leave", " Leave ", true)
                policy_x = button(policy_x, height - 1, "policy_down", " Roll back ", true)
            else
                policy_x = button(policy_x, height - 1, "policy_none", " No migrations ", true)
                policy_x = button(policy_x, height - 1, "policy_up", " Run migrations ", true)
            end
            local parameters = #state.parameters == 0 and "no parameters" or (tostring(#state.parameters) .. " typed parameters")
            if width >= 74 then line(5, "Action " .. state.action .. " · migrations " .. state.policy .. " · " .. parameters, theme.muted) end
        end
        line(height, status ~= "" and status or "↑↓ version · I install · U update · X remove · P prepare · J edit JSON parameter", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = detail and maximum(0, height - 9) or 0, offset = offset}
    end
    local plan = state.plan
    if state.phase == "result" and state.result then
        local result = state.result
        line(3, (result.ok and "Completed" or "Not completed") .. ": " .. result.code, result.ok and theme.accent or theme.text)
        line(4, result.message, theme.text)
        line(6, "Receipt state: " .. result.state .. (result.replayed and "  replayed" or ""), theme.muted)
        button(2, height - 1, "status", " Check status ", state.plan ~= nil)
        button(18, height - 1, "catalog", " Catalog ", true)
        line(height, status ~= "" and status or "R checks this measured operation · Esc returns to catalog", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = 0, offset = 0}
    end
    if not plan then
        line(3, "No plan prepared", theme.muted)
        line(height, status ~= "" and status or "P prepares a plan from the selected package", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = 0, offset = 0}
    end
    line(3, "Plan " .. plan.digest:sub(1, 12) .. "  registry revision " .. tostring(plan.base_revision), theme.muted)
    line(4, plan.ready and "Ready for confirmation" or ("Missing: " .. table.concat(plan.missing, ", ")), plan.ready and theme.accent or theme.text)
    local y = 6
    for _, raw in ipairs(plan.modules) do
        if y >= height - 3 then break end
        local item = raw :: {[string]: unknown}
        line(y, model.text(item.change, 12) .. "  " .. model.text(item.component, 160) .. "  " .. model.text(item.version, 128), theme.text)
        y = y + 1
    end
    if #plan.migrations > 0 and y < height - 3 then line(y, tostring(#plan.migrations) .. " migrations · policy " .. state.policy, theme.muted); y = y + 1 end
    if #plan.capabilities > 0 and y < height - 3 then line(y, tostring(#plan.capabilities) .. " capability entries need review", theme.muted) end
    local actions = 2
    if state.phase == "confirm" then
        line(height - 2, "Confirm this exact digest; changing package, version, policy, or JSON clears it.", theme.text)
        actions = button(actions, height - 1, "confirm", " Confirm ", plan.ready)
        actions = button(actions, height - 1, "cancel", " Back ", true)
        line(height, status ~= "" and status or "Enter confirms · Esc returns to the plan", theme.muted)
    else
        actions = button(actions, height - 1, "review", " Confirm… ", plan.ready)
        actions = button(actions, height - 1, "refresh_plan", " Replan ", true)
        line(height, status ~= "" and status or "Enter reviews immutable plan · R replans · edits invalidate it", theme.muted)
    end
    return {rows = canvas:rows(), hits = hits, capacity = 0, offset = 0}
end

return M

-- MIT. Modules renders model state only. Hit rectangles become application
-- events; this frame neither opens Hub nor confirms an install.
local tty = require("tty")
local json = require("json")
local appearance = require("appearance")
local model = require("model")
local M = {}
local RESET = "\27[0m"
type Hit = {kind: string, key: string, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer, operation_detail_offset: integer}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function request_lines(request: {[string]: unknown}): {string}
    local lines: {string} = {"Request " .. model.text(request.action, 16) .. " " .. model.text(request.component, 160)
        .. "  migrations " .. model.text(request.migration_policy, 16)}
    if request.version ~= nil then lines[1] = lines[1] .. "  version " .. model.text(request.version, 128) end
    if type(request.parameters) == "table" then
        for index, raw in ipairs(request.parameters :: {unknown}) do
            local parameter = type(raw) == "table" and raw :: {[string]: unknown} or {}
            local encoded = json.encode(parameter.value) or "[unavailable]"
            lines[#lines + 1] = "  parameter " .. model.text(parameter.name, 256) .. " = " .. model.text(encoded, #encoded)
            if index >= model.MAX_PARAMETERS then break end
        end
    end
    return lines
end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do if x >= hit.x and y >= hit.y and x < hit.x + hit.width and y < hit.y + hit.height then return hit end end
    return nil
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?): Frame
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
        local active = kind == state.phase or (kind == "readme" and reading == true)
            or (kind == "versions" and reading ~= true) or kind == "confirm" or kind == "review" or kind == "plan"
            or kind == "recover"
        put(x, y, label, size, enabled and (active and appearance.selection_text(theme) or theme.text) or theme.muted,
            enabled and active and theme.accent or theme.surface)
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
    x = button(x, 2, "operations", " Operations ", true)
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
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
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
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "operations" then
        line(3, "Actor-owned operation history", theme.muted)
        local selected_operation = state.selected_operation
        local first = 4
        local list_last = selected_operation and math.max(first - 1, height - 12) or height - 2
        local capacity = maximum(0, math.floor(list_last - first + 1))
        local next_offset = math.floor(math.max(0, math.min(math.max(0, #state.operations - capacity), offset)))
        local page_size = math.max(1, state.operation_page_size)
        local total_pages = math.max(1, math.ceil(state.operation_total / page_size))
        local selected_detail_offset = 0
        if #state.operations == 0 then
            line(first, "No Hub operations recorded for this actor", theme.muted)
        end
        for slot = 1, capacity do
            local item = state.operations[next_offset + slot]
            if not item then break end
            local y, selected = first + slot - 1, selected_operation and selected_operation.digest == item.digest
            local label = item.action .. "  " .. item.component .. "  " .. item.state
            if width >= 72 then label = label .. "  r" .. tostring(item.baseline_revision) end
            line(y, label, selected and appearance.selection_text(theme) or theme.text, selected and theme.accent or theme.surface)
            hits[#hits + 1] = {kind = "operation", key = item.digest, x = 1, y = y, width = width, height = 1}
        end
        if selected_operation then
            local detail_first = first + capacity + 1
            local detail: {string} = {
                "Selected " .. selected_operation.action .. "  " .. selected_operation.component,
                "Digest " .. selected_operation.digest:sub(1, 16) .. "  baseline revision " .. tostring(selected_operation.baseline_revision),
                "State " .. selected_operation.state .. "  " .. selected_operation.message,
            }
            if selected_operation.request then
                for _, line_text in ipairs(request_lines(selected_operation.request)) do detail[#detail + 1] = line_text end
            else
                detail[#detail + 1] = "Request unavailable; this receipt is view-only"
            end
            if #selected_operation.migration_work > 0 then
                detail[#detail + 1] = "Migration work"
                for _, row in ipairs(selected_operation.migration_work) do detail[#detail + 1] = "  " .. model.text(row.id, 256) .. " · " .. model.text(row.status, 32) .. " · " .. model.text(row.target_db, 256) end
            end
            local detail_capacity = maximum(0, height - 3 - detail_first + 1)
            local detail_offset = math.floor(math.max(0, math.min(math.max(0, #detail - detail_capacity), state.operation_detail_offset)))
            selected_detail_offset = detail_offset
            for slot = 1, math.min(detail_capacity, #detail - detail_offset) do line(detail_first + slot - 1, detail[detail_offset + slot], theme.text) end
            if #detail > detail_capacity and detail_capacity > 0 then line(detail_first - 1, "Detail " .. tostring(detail_offset + 1) .. "–" .. tostring(math.min(#detail, detail_offset + detail_capacity)) .. "/" .. tostring(#detail) .. " · PgUp/PgDn scroll detail", theme.muted) end
        end
        local actions = 2
        actions = button(actions, height - 1, "operations_previous", " Prev ", state.operation_page > 1)
        actions = button(actions, height - 1, "operations_next", " Next ", state.operation_page < total_pages)
        if selected_operation and (selected_operation.state == "published" or selected_operation.state == "recovery_required") and selected_operation.request then
            button(actions, height - 1, "recover", " Review recovery… ", true)
        end
        line(height, status ~= "" and status or ("Page " .. tostring(state.operation_page) .. "/" .. tostring(total_pages) .. " · select a receipt to inspect its measured result"), theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = selected_detail_offset}
    end
    local detail = state.detail
    if state.phase == "details" then
        line(3, detail and (detail.title .. "  " .. detail.component) or "Select a package to read its details", theme.muted)
        if detail then
            line(4, detail.description, theme.text)
            local tab_x = 2
            tab_x = button(tab_x, 5, "readme", reading and " [README] " or " README ", true)
            tab_x = button(tab_x, 5, "versions", not reading and " [Versions] " or " Versions ", true)
            if reading then
                local lines: {string} = {}
                local available = maximum(1, width - 4)
                local content = detail.readme .. "\n"
                for paragraph in string.gmatch(content, "([^\n]*)\n") do
                    local row = ""
                    for word in paragraph:gmatch("%S+") do
                        if row ~= "" and tty.text.width(row .. " " .. word) > available then
                            lines[#lines + 1] = row
                            row = ""
                        end
                        row = row == "" and word or (row .. " " .. word)
                    end
                    lines[#lines + 1] = row
                end
                if detail.readme == "" then lines = {"No README provided by this package."} end
                local capacity = maximum(0, height - 8)
                local next_offset = math.floor(math.max(0, math.min(maximum(0, #lines - capacity), offset)))
                for slot = 1, capacity do
                    local row = lines[next_offset + slot]
                    if not row then break end
                    line(6 + slot - 1, row, row:match("^#") and theme.accent or theme.text)
                end
                button(2, height - 1, "versions", " Choose version ", true)
                line(height, status ~= "" and status or "↑↓ scroll · V versions · Esc catalog", theme.muted)
                return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
            end
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
            if width >= 74 then line(height - 3, "Action " .. state.action .. " · migrations " .. state.policy .. " · " .. parameters, theme.muted) end
        end
        line(height, status ~= "" and status or "↑↓ version · H README · I install · U update · X remove · P prepare · J edit JSON parameter", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = detail and maximum(0, height - 9) or 0, offset = offset, operation_detail_offset = 0}
    end
    if state.phase == "confirm" and state.recovery then
        local recovery = state.recovery
        local operation = recovery.operation
        line(3, "Review recovery · immutable receipt", theme.accent)
        line(4, operation.action .. "  " .. operation.component .. "  " .. operation.state, theme.text)
        local body: {string} = {"The stored request will be sent with this digest; no new plan will be prepared."}
        for _, request_line in ipairs(request_lines(recovery.request)) do body[#body + 1] = request_line end
        body[#body + 1] = "Migration work"
        if #operation.migration_work > 0 then
            for _, row in ipairs(operation.migration_work) do body[#body + 1] = model.text(row.id, 256) .. " · " .. model.text(row.status, 32) .. " · " .. model.text(row.target_db, 256) end
        else
            body[#body + 1] = "No migration rows recorded"
        end
        local wrapped: {string} = {}
        local available_width = maximum(2, width - 2)
        for _, raw_line in ipairs(body) do
            local remaining = raw_line
            while tty.text.width(remaining) > available_width do
                local part = tty.text.truncate(remaining, available_width, "")
                if part == "" then break end
                wrapped[#wrapped + 1] = part
                remaining = remaining:sub(#part + 1)
            end
            wrapped[#wrapped + 1] = remaining
        end
        body = wrapped
        local body_capacity = maximum(0, height - 8)
        local body_offset = math.floor(math.max(0, math.min(math.max(0, #body - body_capacity), offset)))
        line(5, "Digest " .. recovery.digest .. (#body > body_capacity and (" · detail " .. tostring(body_offset + 1) .. "–" .. tostring(math.min(#body, body_offset + body_capacity)) .. "/" .. tostring(#body)) or ""), theme.muted)
        for slot = 1, math.min(body_capacity, #body - body_offset) do line(6 + slot - 1, body[body_offset + slot], theme.text) end
        line(height - 2, "Confirming recovery reuses the exact stored request and measured digest.", theme.text)
        local actions = 2
        actions = button(actions, height - 1, "confirm", " Confirm recovery ", true)
        button(actions, height - 1, "cancel", " Back ", true)
        line(height, status ~= "" and status or "Enter confirms · Esc returns to operation history", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = body_capacity, offset = body_offset, operation_detail_offset = 0}
    end
    local plan = state.plan
    if state.phase == "result" and state.result then
        local result = state.result
        line(3, (result.ok and "Completed" or "Not completed") .. ": " .. result.code, result.ok and theme.accent or theme.text)
        line(4, result.message, theme.text)
        line(6, "Receipt state: " .. result.state .. (result.replayed and "  replayed" or ""), theme.muted)
        button(2, height - 1, "status", " Check status ", state.plan ~= nil or state.selected_operation ~= nil)
        button(18, height - 1, "catalog", " Catalog ", true)
        line(height, status ~= "" and status or "R checks this measured operation · Esc returns to catalog", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    if not plan then
        line(3, "No plan prepared", theme.muted)
        line(height, status ~= "" and status or "P prepares a plan from the selected package", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    line(3, "Plan " .. plan.digest:sub(1, 12) .. "  registry revision " .. tostring(plan.base_revision), theme.muted)
    line(4, plan.ready and "Ready for confirmation" or ("Missing: " .. table.concat(plan.missing, ", ")), plan.ready and theme.accent or theme.text)
    local review: {string} = {}
    local unchanged = 0
    for _, item in ipairs(plan.modules) do
        if item.change == "keep" then unchanged = unchanged + 1
        else
            review[#review + 1] = model.text(item.change, 12) .. "  " .. model.text(item.component, 160) .. "  " .. model.text(item.version, 128)
        end
    end
    if unchanged > 0 then review[#review + 1] = tostring(unchanged) .. " installed modules unchanged" end
    for _, missing in ipairs(plan.missing) do review[#review + 1] = "Required: " .. missing end
    if #plan.migrations > 0 then
        review[#review + 1] = "Migrations · policy " .. state.policy
        for _, item in ipairs(plan.migrations) do
            review[#review + 1] = "  " .. model.text(item.id, 256) .. " → " .. model.text(item.target_db, 256)
        end
    end
    if #plan.starts > 0 then
        review[#review + 1] = "Automatic starts"
        for _, id in ipairs(plan.starts) do review[#review + 1] = "  " .. id end
    end
    if #plan.capabilities > 0 then
        review[#review + 1] = "Declared capabilities"
        for _, id in ipairs(plan.capabilities) do review[#review + 1] = "  " .. id end
    end
    if #review == 0 then review = {"No package changes"} end
    local capacity = maximum(0, height - 9)
    local next_offset = math.floor(math.max(0, math.min(maximum(0, #review - capacity), offset)))
    line(5, "Review " .. tostring(math.min(#review, next_offset + 1)) .. "–" .. tostring(math.min(#review, next_offset + capacity))
        .. " of " .. tostring(#review) .. " · ↑↓ scroll", theme.muted)
    for slot = 1, capacity do
        local row = review[next_offset + slot]
        if not row then break end
        line(5 + slot, row, theme.text)
    end
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
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
end

return M

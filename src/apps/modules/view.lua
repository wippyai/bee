-- MIT. Modules renders model state only. Hit rectangles become application
-- events; this frame neither opens Hub nor confirms an install.
local tty = require("tty")
local json = require("json")
local appearance = require("appearance")
local model = require("model")
local contents = require("contents")
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

local function draw_base(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?, content: contents.State?): Frame
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
        local browsing = content ~= nil and content.open
        local active = (kind == "contents" and browsing) or kind == state.phase or (kind == "readme" and reading == true and not state.requirements_open and not browsing)
            or (kind == "versions" and reading ~= true and not state.requirements_open and not browsing)
            or (kind == "requirements" and state.requirements_open) or kind == state.action
            or kind == "policy_" .. state.policy or kind == "confirm" or kind == "review" or kind == "plan"
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
    if state.phase ~= "catalog" and state.phase ~= "installed" then
        x = button(x, 2, "details", " Package ", state.selected ~= nil)
    end
    if state.phase == "catalog" then
        local filters = "Keyword: " .. (state.keyword == "" and "all" or state.keyword) .. "  Search: " .. (state.query == "" and "(none)" or state.query)
        if width < 56 then filters = "Keyword " .. (state.keyword == "" and "all" or state.keyword) end
        line(3, filters, theme.muted)
        local roomy = width >= 48 and height >= 16
        local first = roomy and 6 or 4
        local stride = roomy and 3 or 1
        local capacity = maximum(0, (height - 2 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.catalog - capacity), offset)))
        if roomy then
            local search_x = button(2, 4, "search", " Search packages… ", true)
            search_x = button(search_x, 4, "keyword", " Change keyword ", true)
            put(search_x + 1, 4, tostring(state.total) .. " packages", maximum(0, width - search_x - 2), theme.muted)
        end
        if #state.catalog == 0 then
            line(first, "No packages on this page", theme.text)
            if roomy then line(first + 1, "Try another search or clear the keyword filter.", theme.muted) end
        end
        for slot = 1, capacity do
            local item = state.catalog[next_offset + slot]
            if not item then break end
            local y, selected = first + (slot - 1) * stride, item.component == state.selected
            local label = item.title ~= "" and item.title or item.component
            local foreground = selected and appearance.selection_text(theme) or theme.text
            local background = selected and theme.accent or theme.surface
            if roomy then
                line(y, " " .. label, foreground, background)
                local version_width = tty.text.width(item.latest_version)
                if version_width > 0 and tty.text.width(label) + version_width + 6 < width then
                    put(width - version_width - 2, y, item.latest_version, version_width, foreground, background)
                end
                line(y + 1, " " .. item.component .. "  ·  " .. (item.description ~= "" and item.description or "No description provided"), theme.muted)
                line(y + 2, string.rep("─", maximum(0, width - 4)), theme.border)
            else
                line(y, label, foreground, background)
            end
            hits[#hits + 1] = {kind = "component", key = item.component, x = 1, y = y, width = width, height = stride}
        end
        local actions = 2
        actions = button(actions, height - 1, "previous", " ‹ Previous ", state.page > 1)
        actions = button(actions, height - 1, "next", " Next › ", #state.catalog > 0 and state.total > state.page * #state.catalog)
        line(height, status ~= "" and status or "/ search · K keyword · Enter open · ←/→ page", theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "installed" then
        local roomy = width >= 48 and height >= 16
        line(3, "Your installed packages · " .. tostring(#state.installed), theme.muted)
        local first, stride = roomy and 5 or 4, roomy and 3 or 1
        local capacity = maximum(0, (height - 1 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.installed - capacity), offset)))
        if #state.installed == 0 then
            line(first, "No installed Hub modules", theme.text)
            if roomy then line(first + 1, "Browse the catalog to find your first package.", theme.muted) end
        end
        for slot = 1, capacity do
            local item = state.installed[next_offset + slot]
            if not item then break end
            local y, selected = first + (slot - 1) * stride, item.component == state.selected
            local foreground = selected and appearance.selection_text(theme) or theme.text
            local background = selected and theme.accent or theme.surface
            if roomy then
                local version_width = tty.text.width(item.version)
                local name_width = maximum(0, width - version_width - 7)
                line(y, " " .. tty.text.truncate(item.component, name_width, "…"), foreground, background)
                put(width - version_width - 2, y, item.version, version_width, foreground, background)
                local description = item.direct and "Direct installation" or "Dependency"
                if #item.used_by > 0 then description = description .. " · Required by " .. table.concat(item.used_by, ", ") end
                line(y + 1, " " .. description, theme.muted)
                line(y + 2, string.rep("─", maximum(0, width - 4)), theme.border)
            else
                line(y, item.component .. "  " .. item.version, foreground, background)
            end
            hits[#hits + 1] = {kind = "component", key = item.component, x = 1, y = y, width = width, height = stride}
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
            line(4, (state.selected_version and ("Version " .. state.selected_version .. "  ·  ") or "") .. detail.description, theme.text)
            local tab_x = 2
            tab_x = button(tab_x, 5, "readme", " README ", true)
            tab_x = button(tab_x, 5, "versions", width < 44 and " Vers " or " Versions ", true)
            tab_x = button(tab_x, 5, "requirements", width < 54 and " Config " or " Requirements ", true)
            tab_x = button(tab_x, 5, "contents", " Contents ", state.selected_version ~= nil)
            if content and content.open then
                local capacity = maximum(0, height - 10)
                line(6, content.mode == "entries" and "Read-only package contents" or (content.mode == "entry" and content.path or (content.resource .. " / " .. content.path)), theme.muted)
                local rows: {string} = {}
                if #content.rows == 0 then
                    for _, raw in ipairs(content.lines) do
                        local remaining = raw
                        local available = maximum(1, width - 2)
                        while tty.text.width(remaining) > available do
                            local part = tty.text.truncate(remaining, available, "")
                            if part == "" then break end
                            rows[#rows + 1] = part; remaining = remaining:sub(#part + 1)
                        end
                        rows[#rows + 1] = remaining
                    end
                end
                local next_offset = math.floor(math.max(0, math.min(maximum(0, #rows - capacity), offset)))
                if #content.rows > 0 then next_offset = math.floor(math.max(0, content.selected - capacity)) end
                for slot = 1, capacity do
                    local y = 6 + slot
                    local item = content.rows[next_offset + slot]
                    if item then
                        local active = next_offset + slot == content.selected
                        line(y, item.label, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
                        hits[#hits + 1] = {kind = "content_row", key = item.key, x = 1, y = y, width = width, height = 1}
                    elseif rows[next_offset + slot] then line(y, rows[next_offset + slot], theme.text) end
                end
                local actions = button(2, height - 2, "content_back", " Back ", not content.pending)
                actions = button(actions, height - 2, "content_previous", " Previous ", not content.pending and content.offset > 0)
                button(actions, height - 2, "content_next", " Next page ", not content.pending and content.next_offset ~= nil)
                line(height - 1, content.notice, theme.muted)
                line(height, status ~= "" and status or "↑↓ browse · Enter open · ⌫ back · N next", theme.muted)
                return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
            end
            if state.requirements_open then
                local capacity = maximum(0, math.floor((height - 9) / 3))
                local selected = state.selected_requirement
                local first = math.max(1, selected - capacity + 1)
                if not state.requirements_digest then line(7, state.notice ~= "" and state.notice or "Loading requirements…", theme.muted)
                elseif #state.requirements == 0 then line(7, "This version declares no requirements.", theme.muted) end
                for slot = 1, capacity do
                    local row = state.requirements[first + slot - 1]
                    if not row then break end
                    local y = 6 + (slot - 1) * 3
                    local active = first + slot - 1 == selected
                    line(y, row.id .. " · " .. row.origin, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
                    line(y + 1, row.json == "" and "Choose a JSON value" or row.json, theme.text)
                    line(y + 2, table.concat(row.targets, " · "), theme.muted)
                    hits[#hits + 1] = {kind = "requirement", key = row.id, x = 1, y = y, width = width, height = 3}
                end
                local action_x = button(2, height - 2, "plan", " Prepare ", state.requirements_digest ~= nil)
                local requirement = state.requirements[state.selected_requirement]
                button(action_x, height - 2, "reset_requirement", " Clear override ", requirement ~= nil and requirement.origin == "Selected")
                line(height - 1, "Defaults are used unless you choose a value.", theme.muted)
                line(height, status ~= "" and status or "↑↓ select · Enter edit JSON · V versions · P prepare", theme.muted)
                return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = 0, operation_detail_offset = 0}
            end
            if reading then
                local lines: {string} = {}
                local available = maximum(1, width - 4)
                local content = detail.readme .. "\n"
                local code = false
                for paragraph in string.gmatch(content, "([^\n]*)\n") do
                    if paragraph:match("^%s*```") then
                        code = not code
                        lines[#lines + 1] = code and "── Example ──" or ""
                    elseif code or paragraph:match("^    ") then
                        local remaining = paragraph
                        while tty.text.width(remaining) > available do
                            local part = tty.text.truncate(remaining, available, "")
                            if part == "" then break end
                            lines[#lines + 1] = part
                            remaining = remaining:sub(#part + 1)
                        end
                        lines[#lines + 1] = remaining
                    else
                        local row = ""
                        for word in paragraph:gmatch("%S+") do
                            if row ~= "" and tty.text.width(row .. " " .. word) > available then
                                lines[#lines + 1] = row
                                row = ""
                            end
                            while tty.text.width(word) > available do
                                local part = tty.text.truncate(word, available, "")
                                if part == "" then break end
                                lines[#lines + 1] = part
                                word = word:sub(#part + 1)
                            end
                            row = row == "" and word or (row .. " " .. word)
                        end
                        lines[#lines + 1] = row
                    end
                end
                if detail.readme == "" then lines = {"No README provided by this package."} end
                local capacity = maximum(0, height - 8)
                local next_offset = math.floor(math.max(0, math.min(maximum(0, #lines - capacity), offset)))
                for slot = 1, capacity do
                    local row = lines[next_offset + slot]
                    if not row then break end
                    line(6 + slot - 1, row, row:match("^#") and theme.accent or theme.text)
                end
                local action_x = button(2, height - 1, "versions", " Choose version ", true)
                action_x = button(action_x, height - 1, "requirements", " Configure ", true)
                action_x = button(action_x, height - 1, "plan", " Review installation ", state.selected_version ~= nil)
                line(height, status ~= "" and status or "↑↓ scroll · V versions · C contents · Esc catalog", theme.muted)
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
        line(height, status ~= "" and status or "↑↓ version · I install · U update · X remove · P review", theme.muted)
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
    local required: {[integer]: string} = {}
    local unchanged = 0
    for _, item in ipairs(plan.modules) do
        if item.change == "keep" then unchanged = unchanged + 1
        else
            review[#review + 1] = model.text(item.change, 12) .. "  " .. model.text(item.component, 160) .. "  " .. model.text(item.version, 128)
        end
    end
    if unchanged > 0 then review[#review + 1] = tostring(unchanged) .. " installed modules unchanged" end
    for _, missing in ipairs(plan.missing) do
        review[#review + 1] = "Required: " .. missing .. "  ·  Configure…"
        required[#review] = missing
    end
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
        local missing = required[next_offset + slot]
        line(5 + slot, row, missing and theme.accent or theme.text)
        if missing and state.phase == "plan" then hits[#hits + 1] = {kind = "missing", key = missing, x = 1, y = 5 + slot, width = width, height = 1} end
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
        button(actions, height - 1, "missing", " Configure required ", #plan.missing > 0)
        line(height, status ~= "" and status or "Enter reviews immutable plan · R replans · edits invalidate it", theme.muted)
    end
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
end

type Editor = {field: string, buffer: string, name: string?}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?, editor: Editor?, content: contents.State?): Frame
    local frame = draw_base(width, height, preferences, state, offset, editor and "" or status, reading, content)
    if not editor then return frame end
    if width < 28 or height < 14 then return draw_base(width, height, preferences, state, offset, status, reading, content) end
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    for y, row in ipairs(frame.rows) do canvas:put(1, y, row, width) end
    local w = math.floor(math.min(76, width - 4))
    local h = math.floor(math.min(13, height - 4))
    local left, top = (width - w) // 2 + 1, (height - h) // 2 + 1
    local function row(y: integer, value: string, fg: string?)
        canvas:put(left, y, appearance.style(theme.border, theme.surface) .. "│" .. string.rep(" ", w - 2) .. "│" .. RESET, w)
        canvas:put(left + 2, y, appearance.style(fg or theme.text, theme.surface) .. tty.text.truncate(value, w - 4, "…") .. RESET, w - 4)
    end
    canvas:put(left, top, appearance.style(theme.accent, theme.surface) .. "╭" .. string.rep("─", w - 2) .. "╮" .. RESET, w)
    for y = top + 1, top + h - 2 do row(y, "") end
    local title = editor.field == "query" and "Search packages" or (editor.field == "keyword" and "Filter by keyword" or "Configure package")
    row(top + 1, title, theme.accent)
    row(top + 3, editor.name or (editor.field == "parameter_name" and "Parameter name (namespace:name)" or title), theme.muted)
    local remaining = editor.buffer
    local lines: {string} = {}
    local size = w - 5
    while remaining ~= "" do
        local part = tty.text.truncate(remaining, size, "")
        if part == "" then break end
        lines[#lines + 1] = part
        remaining = remaining:sub(#part + 1)
    end
    local capacity = maximum(1, h - 8)
    local first = maximum(1, #lines - capacity + 1)
    for slot = 1, capacity do
        local value = lines[first + slot - 1] or ""
        if first + slot - 1 == maximum(1, #lines) then value = value .. "▏" end
        row(top + 3 + slot, value)
    end
    local hint = editor.field == "parameter_value" and "JSON: text, number, true/false, object or array" or "Type to edit; Escape keeps the previous value"
    if status:find("not JSON", 1, true) or status:find("required", 1, true) or status:find("cannot", 1, true) then hint = status end
    row(top + h - 3, hint, theme.muted)
    row(top + h - 2, " Enter Save     Esc Cancel", theme.accent)
    canvas:put(left, top + h - 1, appearance.style(theme.accent, theme.surface) .. "╰" .. string.rep("─", w - 2) .. "╯" .. RESET, w)
    local hits: {Hit} = {
        {kind = "save_editor", key = "", x = left + 2, y = top + h - 2, width = 12, height = 1},
        {kind = "cancel_editor", key = "", x = left + 15, y = top + h - 2, width = math.floor(math.min(12, w - 17)), height = 1},
    }
    return {rows = canvas:rows(), hits = hits, capacity = frame.capacity, offset = frame.offset, operation_detail_offset = frame.operation_detail_offset}
end
return M

-- MIT. Modules renders model state only. Hit rectangles become application
-- events; this frame neither opens Hub nor confirms an install.
local tty = require("tty")
local json = require("json")
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local contents = require("contents")
local M = {}
local RESET = "\27[0m"
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer, operation_detail_offset: integer}

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

local function draw_base(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?, content: contents.State?): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    -- Splits each value into rows that fit the body width.
    local function wrap(values: {string}): {string}
        local wrapped: {string} = {}
        local available_width = maximum(2, width - 2)
        for _, raw_line in ipairs(values) do
            local remaining = raw_line
            while tty.text.width(remaining) > available_width do
                local part = tty.text.truncate(remaining, available_width, "")
                if part == "" then break end
                wrapped[#wrapped + 1] = part
                remaining = remaining:sub(#part + 1)
            end
            wrapped[#wrapped + 1] = remaining
        end
        return wrapped
    end
    -- A control is active when it names the current phase, view or choice.
    local function button(x: integer, y: integer, kind: string, label: string, enabled: boolean): integer
        local browsing = content ~= nil and content.open
        local active = (kind == "contents" and browsing) or kind == state.phase or (kind == "readme" and reading == true and not state.requirements_open and not browsing)
            or (kind == "versions" and reading ~= true and not state.requirements_open and not browsing)
            or (kind == "requirements" and state.requirements_open) or kind == state.action
            or kind == "policy_" .. state.policy or kind == "confirm" or kind == "review" or kind == "plan"
            or kind == "recover"
        return frame.button(painter, x, y, {kind = kind, label = label:match("^%s*(.-)%s*$") or label, enabled = enabled, active = active})
    end
    frame.header(painter, "MODULES  " .. string.upper(state.phase), state.selected or "Browse the Hub")
    local x = 2
    x = button(x, 2, "catalog", " Catalog ", true)
    x = button(x, 2, "installed", " Installed ", true)
    x = button(x, 2, "authoring", " Authored ", true)
    x = button(x, 2, "operations", " Operations ", true)
    if state.phase ~= "catalog" and state.phase ~= "installed" then
        x = button(x, 2, "details", " Package ", state.selected ~= nil)
    end
    if state.phase == "catalog" then
        local filters = "Keyword: " .. (state.keyword == "" and "all" or state.keyword) .. "  Search: " .. (state.query == "" and "(none)" or state.query)
        if width < 56 then filters = "Keyword " .. (state.keyword == "" and "all" or state.keyword) end
        frame.line(painter, 3, filters, theme.muted)
        local roomy = width >= 48 and height >= 16
        local first = roomy and 6 or 4
        local stride = roomy and 3 or 1
        local capacity = maximum(0, (height - 2 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.catalog - capacity), offset)))
        if roomy then
            local search_x = button(2, 4, "search", " Search packages… ", true)
            search_x = button(search_x, 4, "keyword", " Change keyword ", true)
            frame.put(painter, search_x + 1, 4, tostring(state.total) .. " packages", maximum(0, width - search_x - 2), theme.muted)
        end
        if #state.catalog == 0 then
            frame.line(painter, first, "No packages on this page", theme.text)
            if roomy then frame.line(painter, first + 1, "Try another search or clear the keyword filter.", theme.muted) end
        end
        for slot = 1, capacity do
            local item = state.catalog[next_offset + slot]
            if not item then break end
            local y, selected = first + (slot - 1) * stride, item.component == state.selected
            local label = item.title ~= "" and item.title or item.component
            local foreground = selected and appearance.selection_text(theme) or theme.text
            local background = selected and theme.accent or theme.surface
            frame.row(painter, y, roomy and (" " .. label) or label, selected, "component", 0, item.component, nil, nil, stride)
            if roomy then
                local version_width = tty.text.width(item.latest_version)
                if version_width > 0 and tty.text.width(label) + version_width + 6 < width then
                    frame.put(painter, width - version_width - 2, y, item.latest_version, version_width, foreground, background)
                end
                frame.line(painter, y + 1, " " .. item.component .. "  ·  " .. (item.description ~= "" and item.description or "No description provided"), theme.muted)
                frame.line(painter, y + 2, string.rep("─", maximum(0, width - 4)), theme.border)
            end
        end
        local actions = 2
        actions = button(actions, height - 1, "previous", " ‹ Previous ", state.page > 1)
        actions = button(actions, height - 1, "next", " Next › ", #state.catalog > 0 and state.total > state.page * #state.catalog)
        frame.footer(painter, status, "/ search · K keyword · Enter open · ←/→ page")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "installed" then
        local roomy = width >= 48 and height >= 16
        frame.line(painter, 3, "Your installed packages · " .. tostring(#state.installed), theme.muted)
        local first, stride = roomy and 5 or 4, roomy and 3 or 1
        local capacity = maximum(0, (height - 1 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.installed - capacity), offset)))
        if #state.installed == 0 then
            frame.line(painter, first, "No installed Hub modules", theme.text)
            if roomy then frame.line(painter, first + 1, "Browse the catalog to find your first package.", theme.muted) end
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
                frame.row(painter, y, " " .. tty.text.truncate(item.component, name_width, "…"), selected, "component", 0, item.component, nil, nil, stride)
                frame.put(painter, width - version_width - 2, y, item.version, version_width, foreground, background)
                local description = item.direct and "Direct installation" or "Dependency"
                if #item.used_by > 0 then description = description .. " · Required by " .. table.concat(item.used_by, ", ") end
                frame.line(painter, y + 1, " " .. description, theme.muted)
                frame.line(painter, y + 2, string.rep("─", maximum(0, width - 4)), theme.border)
            else
                frame.row(painter, y, item.component .. "  " .. item.version, selected, "component", 0, item.component)
            end
        end
        local actions = button(2, height - 1, "refresh", " Refresh ", true)
        frame.footer(painter, status, "↑↓ select · Enter details · R refresh · A authored version")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "authoring" then
        frame.line(painter, 3, "Private authored overlay version", theme.muted)
        frame.line(painter, 4, "Component: " .. (state.publication_component ~= "" and state.publication_component or "(set with C)"), theme.text)
        frame.line(painter, 5, "Version: " .. (state.publication_version ~= "" and state.publication_version or "(set with V)"), theme.text)
        local frozen = state.publication_snapshot_digest ~= "" and state.publication_snapshot_digest or "(freeze first; set with S)"
        frame.line(painter, 6, "Frozen snapshot: " .. frozen, theme.text)
        frame.line(painter, 8, "Freeze the actor-owned overlay, then enter its digest.", theme.muted)
        frame.line(painter, 9, "Prepare stores this exact version locally; it does not distribute it.", theme.muted)
        frame.line(painter, 11, "Overlays: Stage → Review → Select → Approvals → Apply.", theme.text)
        frame.line(painter, 12, "Return here to publish only after this exact version is applied.", theme.text)
        if state.publication_prepared then
            frame.line(painter, 14, "Prepared descriptor " .. state.publication_prepared.descriptor_digest, theme.muted)
        end
        local actions = 2
        actions = button(actions, height - 1, "prepare_publication", " Prepare locally ", true)
        button(actions, height - 1, "publish_publication", " Publish applied version ", model.publication_ready(state))
        frame.footer(painter, status, "C component · V version · S frozen digest · P prepare · U publish")
        if height >= 4 then frame.add_hit(painter, "author_component", 0, "", 1, 4, width, 1) end
        if height >= 5 then frame.add_hit(painter, "author_version", 0, "", 1, 5, width, 1) end
        if height >= 6 then frame.add_hit(painter, "author_snapshot", 0, "", 1, 6, width, 1) end
        return {rows = frame.rows(painter), hits = painter.hits, capacity = 1, offset = 0, operation_detail_offset = 0}
    end
    if state.phase == "operations" then
        frame.line(painter, 3, "Actor-owned operation history", theme.muted)
        local selected_operation = state.selected_operation
        local first = 4
        local list_last = selected_operation and math.max(first - 1, height - 12) or height - 2
        local capacity = maximum(0, math.floor(list_last - first + 1))
        local next_offset = math.floor(math.max(0, math.min(math.max(0, #state.operations - capacity), offset)))
        local page_size = math.max(1, state.operation_page_size)
        local total_pages = math.max(1, math.ceil(state.operation_total / page_size))
        local selected_detail_offset = 0
        if #state.operations == 0 then
            frame.line(painter, first, "No Hub operations recorded for this actor", theme.muted)
        end
        for slot = 1, capacity do
            local item = state.operations[next_offset + slot]
            if not item then break end
            local y, selected = first + slot - 1, selected_operation and selected_operation.digest == item.digest
            local label = item.action .. "  " .. item.component .. "  " .. item.state
            if width >= 72 then label = label .. "  r" .. tostring(item.baseline_revision) end
            frame.row(painter, y, label, selected == true, "operation", 0, item.digest)
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
            for slot = 1, math.min(detail_capacity, #detail - detail_offset) do frame.line(painter, detail_first + slot - 1, detail[detail_offset + slot], theme.text) end
            if #detail > detail_capacity and detail_capacity > 0 then frame.line(painter, detail_first - 1, "Detail " .. tostring(detail_offset + 1) .. "–" .. tostring(math.min(#detail, detail_offset + detail_capacity)) .. "/" .. tostring(#detail) .. " · PgUp/PgDn scroll detail", theme.muted) end
        end
        local actions = 2
        actions = button(actions, height - 1, "operations_previous", " Prev ", state.operation_page > 1)
        actions = button(actions, height - 1, "operations_next", " Next ", state.operation_page < total_pages)
        if selected_operation and (selected_operation.state == "published" or selected_operation.state == "recovery_required") and selected_operation.request then
            button(actions, height - 1, "recover", " Review recovery… ", true)
        end
        frame.footer(painter, status, ("Page " .. tostring(state.operation_page) .. "/" .. tostring(total_pages) .. " · select a receipt to inspect its measured result"))
        return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = selected_detail_offset}
    end
    local detail = state.detail
    if state.phase == "details" then
        frame.line(painter, 3, detail and (detail.title .. "  " .. detail.component) or "Select a package to read its details", theme.muted)
        if detail then
            frame.line(painter, 4, (state.selected_version and ("Version " .. state.selected_version .. "  ·  ") or "") .. detail.description, theme.text)
            local tab_x = 2
            tab_x = button(tab_x, 5, "readme", " README ", true)
            tab_x = button(tab_x, 5, "versions", width < 44 and " Vers " or " Versions ", true)
            tab_x = button(tab_x, 5, "requirements", width < 54 and " Config " or " Requirements ", true)
            tab_x = button(tab_x, 5, "contents", " Contents ", state.selected_version ~= nil)
            if content and content.open then
                local capacity = maximum(0, height - 10)
                frame.line(painter, 6, content.mode == "entries" and "Read-only package contents" or (content.mode == "entry" and content.path or (content.resource .. " / " .. content.path)), theme.muted)
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
                        frame.row(painter, y, item.label, active, "content_row", 0, item.key)
                    elseif rows[next_offset + slot] then frame.line(painter, y, rows[next_offset + slot], theme.text) end
                end
                local actions = button(2, height - 2, "content_back", " Back ", not content.pending)
                actions = button(actions, height - 2, "content_previous", " Previous ", not content.pending and content.offset > 0)
                button(actions, height - 2, "content_next", " Next page ", not content.pending and content.next_offset ~= nil)
                frame.line(painter, height - 1, content.notice, theme.muted)
                frame.footer(painter, status, "↑↓ browse · Enter open · ⌫ back · N next")
                return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
            end
            if state.requirements_open then
                local capacity = maximum(0, math.floor((height - 9) / 3))
                local selected = state.selected_requirement
                local first = math.max(1, selected - capacity + 1)
                if not state.requirements_digest then frame.line(painter, 7, state.notice ~= "" and state.notice or "Loading requirements…", theme.muted)
                elseif #state.requirements == 0 then frame.line(painter, 7, "This version declares no requirements.", theme.muted) end
                for slot = 1, capacity do
                    local row = state.requirements[first + slot - 1]
                    if not row then break end
                    local y = 6 + (slot - 1) * 3
                    local active = first + slot - 1 == selected
                    frame.row(painter, y, row.id .. " · " .. row.origin, active, "requirement", 0, row.id, nil, nil, 3)
                    frame.line(painter, y + 1, row.json == "" and "Choose a JSON value" or row.json, theme.text)
                    frame.line(painter, y + 2, table.concat(row.targets, " · "), theme.muted)
                end
                local action_x = button(2, height - 2, "plan", " Prepare ", state.requirements_digest ~= nil)
                local requirement = state.requirements[state.selected_requirement]
                button(action_x, height - 2, "reset_requirement", " Clear override ", requirement ~= nil and requirement.origin == "Selected")
                frame.line(painter, height - 1, "Defaults are used unless you choose a value.", theme.muted)
                frame.footer(painter, status, "↑↓ select · Enter edit JSON · V versions · P prepare")
                return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = 0, operation_detail_offset = 0}
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
                    frame.line(painter, 6 + slot - 1, row, row:match("^#") and theme.accent or theme.text)
                end
                local action_x = button(2, height - 1, "versions", " Choose version ", true)
                action_x = button(action_x, height - 1, "requirements", " Configure ", true)
                action_x = button(action_x, height - 1, "plan", " Review installation ", state.selected_version ~= nil)
                frame.footer(painter, status, "↑↓ scroll · V versions · C contents · Esc catalog")
                return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
            end
            local first, last = 6, height - 4
            local capacity = maximum(0, last - first + 1)
            local next_offset = math.floor(math.max(0, math.min(maximum(0, #detail.versions - capacity), offset)))
            for slot = 1, capacity do
                local item = detail.versions[next_offset + slot]
                if not item then break end
                local y, selected = first + slot - 1, item.version == state.selected_version
                local label = item.version .. (item.yanked and "  yanked" or "")
                frame.row(painter, y, label, selected, "version", 0, item.version, item.yanked and theme.muted or nil)
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
            if width >= 74 then frame.line(painter, height - 3, "Action " .. state.action .. " · migrations " .. state.policy .. " · " .. parameters, theme.muted) end
        end
        frame.footer(painter, status, "↑↓ version · I install · U update · X remove · P review")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = detail and maximum(0, height - 9) or 0, offset = offset, operation_detail_offset = 0}
    end
    if state.phase == "confirm" and state.recovery then
        local recovery = state.recovery
        local operation = recovery.operation
        frame.line(painter, 3, "Review recovery · immutable receipt", theme.accent)
        frame.line(painter, 4, operation.action .. "  " .. operation.component .. "  " .. operation.state, theme.text)
        local body: {string} = {"The stored request will be sent with this digest; no new plan will be prepared."}
        for _, request_line in ipairs(request_lines(recovery.request)) do body[#body + 1] = request_line end
        body[#body + 1] = "Migration work"
        if #operation.migration_work > 0 then
            for _, row in ipairs(operation.migration_work) do body[#body + 1] = model.text(row.id, 256) .. " · " .. model.text(row.status, 32) .. " · " .. model.text(row.target_db, 256) end
        else
            body[#body + 1] = "No migration rows recorded"
        end
        body = wrap(body)
        local body_capacity = maximum(0, height - 8)
        local body_offset = math.floor(math.max(0, math.min(math.max(0, #body - body_capacity), offset)))
        frame.line(painter, 5, "Digest " .. recovery.digest .. (#body > body_capacity and (" · detail " .. tostring(body_offset + 1) .. "–" .. tostring(math.min(#body, body_offset + body_capacity)) .. "/" .. tostring(#body)) or ""), theme.muted)
        for slot = 1, math.min(body_capacity, #body - body_offset) do frame.line(painter, 6 + slot - 1, body[body_offset + slot], theme.text) end
        frame.line(painter, height - 2, "Confirming recovery reuses the exact stored request and measured digest.", theme.text)
        local actions = 2
        actions = button(actions, height - 1, "confirm", " Confirm recovery ", true)
        button(actions, height - 1, "cancel", " Back ", true)
        frame.footer(painter, status, "Enter confirms · Esc returns to operation history")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = body_capacity, offset = body_offset, operation_detail_offset = 0}
    end
    local plan = state.plan
    if state.phase == "result" and state.result then
        local result = state.result
        frame.line(painter, 3, (result.ok and "Completed" or "Not completed") .. ": " .. result.code, result.ok and theme.accent or theme.text)
        local message = wrap({result.message})
        local message_capacity = maximum(1, height - 8)
        local shown = #message
        if shown > message_capacity then shown = message_capacity end
        for slot = 1, shown do
            local value = message[slot]
            if slot == message_capacity and #message > message_capacity then value = tty.text.truncate(value .. " …", maximum(0, width - 2), "…") end
            frame.line(painter, 3 + slot, value, theme.text)
        end
        frame.line(painter, 5 + shown, "Receipt state: " .. result.state .. (result.replayed and "  replayed" or ""), theme.muted)
        button(2, height - 1, "status", " Check status ", state.plan ~= nil or state.selected_operation ~= nil)
        button(18, height - 1, "catalog", " Catalog ", true)
        frame.footer(painter, status, "R checks this measured operation · Esc returns to catalog")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    if not plan then
        frame.line(painter, 3, "No plan prepared", theme.muted)
        frame.footer(painter, status, "P prepares a plan from the selected package")
        return {rows = frame.rows(painter), hits = painter.hits, capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    frame.line(painter, 3, "Plan " .. plan.digest:sub(1, 12) .. "  registry revision " .. tostring(plan.base_revision), theme.muted)
    frame.line(painter, 4, plan.ready and "Ready for confirmation" or ("Missing: " .. table.concat(plan.missing, ", ")), plan.ready and theme.accent or theme.text)
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
    frame.line(painter, 5, "Review " .. tostring(math.min(#review, next_offset + 1)) .. "–" .. tostring(math.min(#review, next_offset + capacity))
        .. " of " .. tostring(#review) .. " · ↑↓ scroll", theme.muted)
    for slot = 1, capacity do
        local row = review[next_offset + slot]
        if not row then break end
        local missing = required[next_offset + slot]
        frame.line(painter, 5 + slot, row, missing and theme.accent or theme.text)
        if missing and state.phase == "plan" then frame.add_hit(painter, "missing", 0, missing, 1, 5 + slot, width, 1) end
    end
    local actions = 2
    if state.phase == "confirm" then
        frame.line(painter, height - 2, "Confirm this exact digest; changing package, version, policy, or JSON clears it.", theme.text)
        actions = button(actions, height - 1, "confirm", " Confirm ", plan.ready)
        actions = button(actions, height - 1, "cancel", " Back ", true)
        frame.footer(painter, status, "Enter confirms · Esc returns to the plan")
    else
        actions = button(actions, height - 1, "review", " Confirm… ", plan.ready)
        actions = button(actions, height - 1, "refresh_plan", " Replan ", true)
        button(actions, height - 1, "missing", " Configure required ", #plan.missing > 0)
        frame.footer(painter, status, "Enter reviews immutable plan · R replans · edits invalidate it")
    end
    return {rows = frame.rows(painter), hits = painter.hits, capacity = capacity, offset = next_offset, operation_detail_offset = 0}
end

type Editor = {field: string, buffer: string, name: string?}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?, editor: Editor?, content: contents.State?): Frame
    local base = draw_base(width, height, preferences, state, offset, editor and "" or status, reading, content)
    if not editor then return base end
    local theme = appearance.theme(preferences.theme)
    local publication_editor = editor.field == "publication_component" or editor.field == "publication_version"
        or editor.field == "publication_snapshot_digest"
    local title = editor.field == "query" and "Search packages" or (editor.field == "keyword" and "Filter by keyword"
        or (publication_editor and "Authored overlay version" or "Configure package"))
    -- The editor remains the active mode after a resize. A compact frame must
    -- therefore keep that mode visible and must never expose the underlying
    -- page's hit targets while keystrokes still edit the buffer.
    if width < 28 or height < 14 then
        local compact = tty.canvas(width, height)
        compact:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
        local function compact_line(y: integer, value: string, fg: string?)
            if y < 1 or y > height or width < 1 then return end
            compact:put(1, y, appearance.style(fg or theme.text, theme.surface)
                .. tty.text.truncate(value, width, "…") .. RESET, width)
        end
        compact_line(1, "EDIT · " .. title, theme.accent)
        compact_line(2, (editor.buffer ~= "" and editor.buffer or "(empty)") .. "▏")
        if height > 2 then compact_line(height, status ~= "" and status or "Enter save · Esc cancel", theme.muted) end
        local compact_hits: {frame.Hit} = {}
        if width >= 24 and height > 2 then
            compact_hits = {
                {kind = "save_editor", index = 0, key = "", x = 1, y = height, width = 10, height = 1},
                {kind = "cancel_editor", index = 0, key = "", x = 14, y = height, width = 10, height = 1},
            }
        end
        return {rows = compact:rows(), hits = compact_hits, capacity = 0,
            offset = base.offset, operation_detail_offset = base.operation_detail_offset}
    end
    local canvas = tty.canvas(width, height)
    for y, row in ipairs(base.rows) do canvas:put(1, y, row, width) end
    local w = math.floor(math.min(76, width - 4))
    local h = math.floor(math.min(13, height - 4))
    local left, top = (width - w) // 2 + 1, (height - h) // 2 + 1
    local function row(y: integer, value: string, fg: string?)
        canvas:put(left, y, appearance.style(theme.border, theme.surface) .. "│" .. string.rep(" ", w - 2) .. "│" .. RESET, w)
        canvas:put(left + 2, y, appearance.style(fg or theme.text, theme.surface) .. tty.text.truncate(value, w - 4, "…") .. RESET, w - 4)
    end
    canvas:put(left, top, appearance.style(theme.accent, theme.surface) .. "╭" .. string.rep("─", w - 2) .. "╮" .. RESET, w)
    for y = top + 1, top + h - 2 do row(y, "") end
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
    local hint = editor.field == "parameter_value" and "JSON: text, number, true/false, object or array"
        or (editor.field == "publication_snapshot_digest" and "64 lowercase hex characters from Governance Freeze"
        or "Type to edit; Escape keeps the previous value")
    if status:find("not JSON", 1, true) or status:find("required", 1, true) or status:find("cannot", 1, true) then hint = status end
    row(top + h - 3, hint, theme.muted)
    row(top + h - 2, " Enter Save     Esc Cancel", theme.accent)
    canvas:put(left, top + h - 1, appearance.style(theme.accent, theme.surface) .. "╰" .. string.rep("─", w - 2) .. "╯" .. RESET, w)
    local hits: {frame.Hit} = {
        {kind = "save_editor", index = 0, key = "", x = left + 2, y = top + h - 2, width = 12, height = 1},
        {kind = "cancel_editor", index = 0, key = "", x = left + 15, y = top + h - 2, width = math.floor(math.min(12, w - 17)), height = 1},
    }
    return {rows = canvas:rows(), hits = hits, capacity = base.capacity, offset = base.offset, operation_detail_offset = base.operation_detail_offset}
end
return M

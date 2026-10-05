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
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer, operation_detail_offset: integer}
-- One line of a plan review: a heading with an optional summary, or an item;
-- missing names the requirement an item configures.
type ReviewLine = {text: string, heading: boolean, summary: string?, missing: string?}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
-- align pads value to width cells and keeps a longer value whole.
local function align(value: string, width: integer): string
    return value .. string.rep(" ", maximum(0, width - tty.text.width(value)))
end
local function request_lines(request: {[string]: unknown}): {string}
    local lines: {string} = {"Request " .. model.text(request.action, 16) .. " " .. model.text(request.component, 160)
        .. "  migrations " .. model.text(request.migration_policy, 16)}
    if request.version ~= nil then lines[1] = lines[1] .. "  version " .. model.text(request.version, 128) end
    if type(request.parameters) == "table" then
        for index, raw in ipairs(request.parameters) do
            local parameter = type(raw) == "table" and raw or {}
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
            or (kind == "developer_packages" and state.developer_packages)
        return frame.button(painter, x, y, {kind = kind, label = label:match("^%s*(.-)%s*$") or label, enabled = enabled, active = active,
            primary = kind == "confirm" or kind == "review" or kind == "plan" or kind == "recover"})
    end
    frame.header(painter, "MODULES  " .. string.upper(state.phase), state.selected or "Browse the Hub")
    local x = 2
    x = button(x, 2, "catalog", " Catalog ", true)
    x = button(x, 2, "installed", " Installed ", true)
    x = button(x, 2, "operations", " Operations ", true)
    if state.phase ~= "catalog" and state.phase ~= "installed" then
        x = button(x, 2, "details", " Package ", state.selected ~= nil)
    end
    if state.phase == "catalog" then
        local filters = "Keyword " .. (state.keyword == "" and "all" or state.keyword) .. " · Search " .. (state.query == "" and "none" or state.query)
        if width < 56 then filters = "Keyword " .. (state.keyword == "" and "all" or state.keyword) end
        frame.line(painter, 3, filters, theme.muted)
        local roomy = width >= 48 and height >= 16
        local first = roomy and 6 or 4
        local stride = roomy and 3 or 1
        local catalog_items = model.visible_catalog(state)
        local capacity = maximum(0, (height - 2 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #catalog_items - capacity), offset)))
        if roomy then
            local search_x = button(2, 4, "search", " Search packages… ", true)
            search_x = button(search_x, 4, "keyword", " Change keyword ", true)
            local dev_label = state.developer_packages and " Developer packages [x] " or " Developer packages "
            if width < 76 then
                dev_label = state.developer_packages and " Dev pkgs [x] " or " Dev pkgs "
            end
            button(search_x, 4, "developer_packages", dev_label, true)
            local count_str = tostring(#catalog_items) .. (state.all_catalog and #state.all_catalog > #catalog_items and ("/" .. tostring(state.total)) or "") .. " packages"
            frame.section(painter, 5, "Packages", count_str .. " · page " .. tostring(state.page))
        end
        if #catalog_items == 0 then
            if state.all_catalog and #state.all_catalog > 0 then
                frame.line(painter, first, "No packages on this page", theme.text)
                if roomy then frame.line(painter, first + 1, "Developer packages are hidden · enable Developer packages to show libraries.", theme.muted) end
            else
                frame.empty(painter, first, "No packages found", "/ change the search · K change the keyword")
            end
        end
        for slot = 1, capacity do
            local item = catalog_items[next_offset + slot]
            if not item then break end
            local y, selected = first + (slot - 1) * stride, item.component == state.selected
            local label = item.title ~= "" and item.title or item.component
            local status = model.component_status(state, item.component)
            local foreground = selected and appearance.selection_text(theme) or theme.text
            local background = selected and theme.accent or theme.surface
            local row_label = roomy and (" " .. label) or label
            if not roomy then
                if status == "built-in" then row_label = label .. " [built-in]"
                elseif status == "installed" then row_label = label .. " [installed]"
                else row_label = label .. " [install]" end
            end
            frame.row(painter, y, row_label, selected, "component", 0, item.component, nil, nil, stride)
            if roomy then
                local action_tag = ""
                if status == "built-in" then
                    action_tag = item.latest_version ~= "" and ("Built-in · Open " .. item.latest_version) or "Built-in · Open"
                elseif status == "installed" then
                    action_tag = item.latest_version ~= "" and ("Installed · Open " .. item.latest_version) or "Installed · Open"
                else
                    action_tag = item.latest_version ~= "" and ("Install " .. item.latest_version) or "Install"
                end
                local tag_width = tty.text.width(action_tag)
                if tag_width > 0 and tty.text.width(label) + tag_width + 6 < width then
                    frame.put(painter, width - tag_width - 2, y, action_tag, tag_width, foreground, background)
                elseif tty.text.width(item.latest_version) > 0 and tty.text.width(label) + tty.text.width(item.latest_version) + 6 < width then
                    frame.put(painter, width - tty.text.width(item.latest_version) - 2, y, item.latest_version, tty.text.width(item.latest_version), foreground, background)
                end
                frame.line(painter, y + 1, " " .. item.component .. "  ·  " .. (item.description ~= "" and item.description or "No description provided"), theme.muted)
            end
        end
        local sel_status = state.selected and model.component_status(state, state.selected)
        local actions = 2
        actions = button(actions, height - 1, "previous", " ‹ Previous ", state.page > 1)
        actions = button(actions, height - 1, "next", " Next › ", #state.catalog > 0 and state.total > state.page * #state.catalog)
        actions = button(actions, height - 1, "details", (sel_status == "built-in" or sel_status == "installed") and " Open " or " Install ", state.selected ~= nil)
        local action_hint = (sel_status == "built-in" or sel_status == "installed") and "Enter open" or "Enter install"
        frame.footer(painter, status, "/ search · K keyword · " .. action_hint .. " · ←/→ page")
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "installed" then
        local roomy = width >= 48 and height >= 16
        if roomy then frame.section(painter, 4, "Installed packages", tostring(#state.installed) .. (#state.installed == 1 and " package" or " packages"))
        else frame.line(painter, 3, "Your installed packages · " .. tostring(#state.installed), theme.muted) end
        local first, stride = roomy and 5 or 4, roomy and 3 or 1
        local capacity = maximum(0, (height - 1 - first) // stride)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #state.installed - capacity), offset)))
        if #state.installed == 0 then
            frame.empty(painter, first, "No packages installed", "Browse the catalog to choose a package")
            if roomy then frame.line(painter, first + 1, "Browse the catalog to find your first package.", theme.muted) end
        end
        for slot = 1, capacity do
            local item = state.installed[next_offset + slot]
            if not item then break end
            local y, selected = first + (slot - 1) * stride, item.component == state.selected
            local foreground = selected and appearance.selection_text(theme) or theme.text
            local background = selected and theme.accent or theme.surface
            if roomy then
                local update: model.PackUpdate? = nil
                for _, candidate in ipairs(state.pack_updates) do
                    if candidate.component == item.component then update = candidate; break end
                end
                local version_width = tty.text.width(item.version)
                local name_width = maximum(0, width - version_width - 7)
                frame.row(painter, y, " " .. tty.text.truncate(item.component, name_width, "…"), selected, "component", 0, item.component, nil, nil, stride)
                frame.put(painter, width - version_width - 2, y, item.version, version_width, foreground, background)
                local description = item.direct and "Direct installation" or "Dependency"
                if #item.used_by > 0 then description = description .. " · Required by " .. table.concat(item.used_by, ", ") end
                if update then
                    if update.available_version ~= "" then
                        description = description .. " · Hub " .. update.available_version
                        if item.component == "bee/bee" and state.bee_update and state.bee_update.needs_new_binary then
                            description = description .. " · needs a newer Bee binary"
                        elseif item.component == "bee/bee" and state.bee_update and state.bee_update.update_available then
                            description = description .. " · U updates the Bee deployment"
                        elseif update.update_available then description = description .. " · component update available" end
                    elseif state.update_status == "pending" then description = description .. " · checking Hub version…" end
                end
                frame.line(painter, y + 1, " " .. description, theme.muted)
            else
                local label = item.component .. "  " .. item.version
                for _, candidate in ipairs(state.pack_updates) do
                    if candidate.component == item.component and candidate.available_version ~= "" then
                        label = label .. " · Hub " .. candidate.available_version
                        if candidate.update_available then label = label .. " · update available" end
                        break
                    end
                end
                frame.row(painter, y, label, selected, "component", 0, item.component)
            end
        end
        local actions = button(2, height - 1, "refresh", " Refresh ", true)
        local update = state.bee_update
        if update and update.update_available then
            actions = button(actions, height - 1, "bee_update", " Update Bee ", not update.needs_new_binary)
        end
        frame.footer(painter, status, "↑↓ select · Enter details · U update Bee · R refresh")
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = 0}
    end
    if state.phase == "operations" then
        frame.section(painter, 4, "Operations", "Actor-owned operation history")
        local selected_operation = state.selected_operation
        local first = 5
        -- A selected receipt takes the rows below the list: a gap, its heading and its detail.
        local list_last = selected_operation and math.max(first - 1, height - 13) or height - 2
        local capacity = maximum(0, math.floor(list_last - first + 1))
        local next_offset = math.floor(math.max(0, math.min(math.max(0, #state.operations - capacity), offset)))
        local page_size = math.max(1, state.operation_page_size)
        local total_pages = math.max(1, math.ceil(state.operation_total / page_size))
        local selected_detail_offset = 0
        if #state.operations == 0 then
            frame.empty(painter, first, "No package changes recorded", "Choose a package in the catalog to review a change")
        end
        for slot = 1, capacity do
            local item = state.operations[next_offset + slot]
            if not item then break end
            local y, selected = first + slot - 1, selected_operation and selected_operation.digest == item.digest
            local label = align(item.action, 10) .. "  " .. align(item.component, 28) .. "  " .. item.state
            if width >= 72 then label = label .. string.rep(" ", maximum(0, 18 - tty.text.width(item.state))) .. "  r" .. tostring(item.baseline_revision) end
            frame.row(painter, y, label, selected == true, "operation", 0, item.digest)
        end
        if selected_operation then
            local detail_first = first + capacity + 2
            local detail: {string} = {
                align("Selected", 10) .. selected_operation.action .. "  " .. selected_operation.component,
                align("Digest", 10) .. selected_operation.digest:sub(1, 16) .. "  baseline revision " .. tostring(selected_operation.baseline_revision),
                align("State", 10) .. selected_operation.state .. "  " .. selected_operation.message,
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
            for slot = 1, math.min(detail_capacity, #detail - detail_offset) do frame.line(painter, detail_first + slot - 1, "  " .. detail[detail_offset + slot], theme.text) end
            local range = ""
            if #detail > detail_capacity and detail_capacity > 0 then range = tostring(detail_offset + 1) .. "–" .. tostring(math.min(#detail, detail_offset + detail_capacity)) .. "/" .. tostring(#detail) .. " · PgUp/PgDn scroll" end
            if detail_capacity > 0 then frame.section(painter, detail_first - 1, "Receipt", range) end
        end
        local actions = 2
        actions = button(actions, height - 1, "operations_previous", " Prev ", state.operation_page > 1)
        actions = button(actions, height - 1, "operations_next", " Next ", state.operation_page < total_pages)
        if selected_operation and (selected_operation.state == "prepared" or selected_operation.state == "published" or selected_operation.state == "recovery_required") and selected_operation.request then
            button(actions, height - 1, "recover", " Review recovery… ", true)
        end
        frame.footer(painter, status, ("Page " .. tostring(state.operation_page) .. "/" .. tostring(total_pages) .. " · select a receipt to inspect its measured result"))
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = selected_detail_offset}
    end
    local detail = state.detail
    if state.phase == "details" then
        local detail_status = detail and model.component_status(state, detail.component)
        local status_suffix = detail_status and ("  ·  " .. (detail_status == "built-in" and "Built-in" or "Installed")) or ""
        if detail then
            -- The package's title stands out; its name and state follow dimmed.
            frame.fill(painter, 3)
            local drawn = frame.put(painter, 2, 3, detail.title, width - 2, theme.accent)
            frame.put(painter, 2 + drawn + 2, 3, detail.component .. status_suffix, width - drawn - 4, theme.muted)
        else
            frame.line(painter, 3, "Select a package to read its details", theme.muted)
        end
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
                return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = 0}
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
                return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = 0, operation_detail_offset = 0}
            end
            if reading then
                local lines: {string} = {}
                local available = maximum(1, width - 4)
                local content = detail.readme .. "\n"
                local code = false
                -- Prose reflows to the width: a paragraph's source lines join
                -- until a blank line, a heading, a list item, a quote, a table
                -- row or code starts the next block.
                local pending = ""
                local function flush()
                    if pending == "" then return end
                    local row = ""
                    for word in pending:gmatch("%S+") do
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
                    pending = ""
                end
                for paragraph in string.gmatch(content, "([^\n]*)\n") do
                    if paragraph:match("^%s*```") then
                        flush()
                        code = not code
                        lines[#lines + 1] = code and "── Example ──" or ""
                    elseif code or paragraph:match("^    ") then
                        flush()
                        local remaining = paragraph
                        while tty.text.width(remaining) > available do
                            local part = tty.text.truncate(remaining, available, "")
                            if part == "" then break end
                            lines[#lines + 1] = part
                            remaining = remaining:sub(#part + 1)
                        end
                        lines[#lines + 1] = remaining
                    elseif paragraph:match("^%s*$") then
                        flush()
                        lines[#lines + 1] = ""
                    elseif paragraph:match("^#") then
                        flush()
                        pending = paragraph
                        flush()
                    elseif paragraph:match("^%s*[-*+] ") or paragraph:match("^%s*%d+[.)] ") or paragraph:match("^%s*[>|]") then
                        flush()
                        pending = paragraph
                    else
                        pending = pending == "" and paragraph or (pending .. " " .. paragraph)
                    end
                end
                flush()
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
                return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = 0}
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
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = detail and maximum(0, height - 9) or 0, offset = offset, operation_detail_offset = 0}
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
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = body_capacity, offset = body_offset, operation_detail_offset = 0}
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
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    if not plan then
        frame.empty(painter, 3, "No changes prepared", "Choose a package and press P to review changes")
        frame.footer(painter, status, "P prepares a plan from the selected package")
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = 0, offset = 0, operation_detail_offset = 0}
    end
    frame.line(painter, 3, "Plan " .. plan.digest:sub(1, 12) .. "  registry revision " .. tostring(plan.base_revision), theme.muted)
    frame.line(painter, 4, plan.ready and "Ready for confirmation" or ("Missing: " .. table.concat(plan.missing, ", ")), plan.ready and theme.accent or theme.text)
    -- The review lists each part of the plan under its heading, a gap before
    -- each heading but the first, items indented under it.
    local review: {ReviewLine} = {}
    local function heading(title: string, summary: string?)
        if #review > 0 then review[#review + 1] = {text = "", heading = false} end
        review[#review + 1] = {text = title, heading = true, summary = summary}
    end
    local function item(text: string, missing: string?)
        review[#review + 1] = {text = "  " .. text, heading = false, missing = missing}
    end
    if plan.conversion then
        heading("Ownership", "transfer component roots to host ownership")
        for _, root in ipairs(plan.conversion.roots) do item(root.component) end
    end
    local unchanged = 0
    local changes: {string} = {}
    local name_width = 0
    for _, entry in ipairs(plan.modules) do name_width = maximum(name_width, tty.text.width(model.text(entry.component, 160))) end
    name_width = math.floor(math.min(32, name_width))
    for _, entry in ipairs(plan.modules) do
        local name = align(model.text(entry.component, 160), name_width)
        if entry.change == "keep" then
            unchanged = unchanged + 1
            if type(entry.reason) == "string" then
                changes[#changes + 1] = align("keep", 8) .. "  " .. name .. "  " .. model.text(entry.reason, 4096)
            end
        else
            changes[#changes + 1] = align(model.text(entry.change, 12), 8) .. "  " .. name .. "  " .. model.text(entry.version, 128)
        end
    end
    if #changes > 0 or unchanged > 0 then
        heading("Packages", unchanged > 0 and (tostring(unchanged) .. " installed modules unchanged") or nil)
        for _, text in ipairs(changes) do item(text) end
    end
    if #plan.missing > 0 then
        heading("Required")
        for _, missing in ipairs(plan.missing) do item("Required: " .. missing .. "  ·  Configure…", missing) end
    end
    if #plan.migrations > 0 then
        heading("Migrations", "policy " .. state.policy)
        for _, migration in ipairs(plan.migrations) do item(model.text(migration.id, 256) .. " → " .. model.text(migration.target_db, 256)) end
    end
    if #plan.starts > 0 then
        heading("Automatic starts")
        for _, id in ipairs(plan.starts) do item(id) end
    end
    if #plan.capabilities > 0 then
        heading("Declared capabilities")
        for _, id in ipairs(plan.capabilities) do item(id) end
    end
    if #review == 0 then review = {{text = "No package changes", heading = false}} end
    local capacity = maximum(0, height - 9)
    local next_offset = math.floor(math.max(0, math.min(maximum(0, #review - capacity), offset)))
    frame.line(painter, 5, "Review " .. tostring(math.min(#review, next_offset + 1)) .. "–" .. tostring(math.min(#review, next_offset + capacity))
        .. " of " .. tostring(#review) .. " · ↑↓ scroll", theme.muted)
    for slot = 1, capacity do
        local row = review[next_offset + slot]
        if not row then break end
        local y = 5 + slot
        if row.heading then frame.section(painter, y, row.text, row.summary)
        else
            frame.line(painter, y, row.text, row.missing and theme.accent or theme.text)
            if row.missing and state.phase == "plan" then frame.add_hit(painter, "missing", 0, row.missing, 1, y, width, 1) end
        end
    end
    local actions = 2
    if state.phase == "confirm" then
        frame.line(painter, height - 2, "Duration: once, for this exact digest; edits clear confirmation.", theme.text)
        actions = button(actions, height - 1, "confirm", " Confirm ", plan.ready)
        actions = button(actions, height - 1, "cancel", " Back ", true)
        frame.footer(painter, status, "Enter confirms · Esc returns to the plan")
    else
        actions = button(actions, height - 1, "review", " Confirm… ", plan.ready)
        actions = button(actions, height - 1, "refresh_plan", " Replan ", true)
        button(actions, height - 1, "missing", " Configure required ", #plan.missing > 0)
        frame.footer(painter, status, "Enter reviews immutable plan · R replans · edits invalidate it")
    end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter), capacity = capacity, offset = next_offset, operation_detail_offset = 0}
end

type Editor = {field: string, buffer: string, name: string?}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string, reading: boolean?, editor: Editor?, content: contents.State?): Frame
    local base = draw_base(width, height, preferences, state, offset, editor and "" or status, reading, content)
    if not editor then return base end
    local theme = preferences.theme
    local title = editor.field == "query" and "Search packages" or (editor.field == "keyword" and "Filter by keyword"
        or "Configure package")
    -- The editor remains the active mode after a resize. A compact frame must
    -- therefore keep that mode visible and must never expose the underlying
    -- page's hit targets while keystrokes still edit the buffer.
    if width < 28 or height < 14 then
        local compact_painter = frame.new(width, height, preferences)
        local compact = compact_painter.canvas
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
        return {rows = frame.rows(compact_painter), hits = compact_hits, capacity = 0,
            offset = base.offset, operation_detail_offset = base.operation_detail_offset}
    end
    local editor_painter = frame.new(width, height, preferences)
    local canvas = editor_painter.canvas
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
        or "Type to edit; Escape keeps the previous value"
    if status:find("not JSON", 1, true) or status:find("required", 1, true) or status:find("cannot", 1, true) then hint = status end
    row(top + h - 3, hint, theme.muted)
    row(top + h - 2, " Enter Save     Esc Cancel", theme.accent)
    canvas:put(left, top + h - 1, appearance.style(theme.accent, theme.surface) .. "╰" .. string.rep("─", w - 2) .. "╯" .. RESET, w)
    local hits: {frame.Hit} = {
        {kind = "save_editor", index = 0, key = "", x = left + 2, y = top + h - 2, width = 12, height = 1},
        {kind = "cancel_editor", index = 0, key = "", x = left + 15, y = top + h - 2, width = math.floor(math.min(12, w - 17)), height = 1},
    }
    return {rows = frame.rows(editor_painter), hits = hits, capacity = base.capacity, offset = base.offset, operation_detail_offset = base.operation_detail_offset}
end
return M

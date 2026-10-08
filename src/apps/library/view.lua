-- MIT. The Library frame: three tabs of applications and packages in one
-- table each, a version screen for what other bees and agents shared, and the
-- Hub package screens. Technical words appear only in the details view.
local appearance = require("appearance")
local glyphs = require("glyphs")
local frame = require("frame")
local model = require("model")
local governed = require("governed")
local hub = require("hub")
local hub_view = require("hub_view")
local contents = require("contents")
local text = require("text")

type Editor = {field: string, buffer: string, name: string?}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?, capacity: integer, offset: integer, operation_detail_offset: integer}
-- What the application keeps besides the model: scroll offset, the status it
-- owns, the Hub reading mode, an open editor and the package contents browser.
type Ui = {offset: integer, status: string, reading: boolean, editor: Editor?, content: contents.State}
local M = {}

local TABS: {frame.Tab} = {{kind = "tab_installed", label = "Installed", short = "I"},
    {kind = "tab_shared", label = "Shared", short = "S"}, {kind = "tab_history", label = "History", short = "H"}}
local HINTS = frame.hints({{key = "Tab", verb = "view"}, {key = "↑↓", verb = "select"}, {key = "Esc", verb = "close"}})
local TECHNICAL_HINTS = frame.hints({{key = "T", verb = "details"}, {key = "R", verb = "refresh"}, {key = "A", verb = "accept"},
    {key = "N", verb = "reject"}, {key = "S", verb = "select"}, {key = "P", verb = "prepare"}, {key = "X", verb = "apply"},
    {key = "I", verb = "status"}, {key = "G", verb = "recover"}})
local PACKAGE_PHASES: {[string]: boolean} = {details = true, plan = true, confirm = true, result = true}

local function bare(label: string): string
    local value = label:match("^%s*(.-)%s*$")
    return value or label
end

-- The tab a tab hit selects, or nil for any other hit kind.
function M.tab_of(kind: string): model.Tab?
    if kind == "tab_installed" then return "installed" end
    if kind == "tab_shared" then return "shared" end
    if kind == "tab_history" then return "history" end
    return nil
end

-- Which screen shows: the Hub package screens while the Hub model holds one of
-- their phases, the version screen while one is open, else the tab's list.
function M.screen(state: model.State): string
    if PACKAGE_PHASES[state.hub.phase] then return "package" end
    return state.screen
end

type Button = frame.Button

-- The Hub filters of the Shared tab: search text, keyword and whether
-- developer packages show.
local function filters(state: model.State): {Button}
    local found: {Button} = {{kind = "hub_catalog", key = "H", label = glyphs.package .. " Hub catalog", enabled = true, active = state.hub_open}}
    if state.hub_open then
        found[#found + 1] = {kind = "search", key = "/", label = "Search packages…", enabled = true}
        found[#found + 1] = {kind = "keyword", key = "K", label = "Keyword " .. (state.hub.keyword == "" and "all" or state.hub.keyword), enabled = true}
        found[#found + 1] = {kind = "developer_packages", label = state.hub.developer_packages and "Developer packages [x]" or "Developer packages",
            enabled = true, active = state.hub.developer_packages}
    end
    return found
end

-- The buttons for the chosen row: its primary move first, then the rest.
function M.actions(state: model.State, row: model.Row?, with_filters: boolean?): {Button}
    local buttons: {Button} = {}
    if M.screen(state) == "version" then
        local status = row and row.status or ""
        if status == model.STATUS_SHARED then
            buttons[#buttons + 1] = {kind = "install", key = "Enter", label = "Install", enabled = true, primary = true}
        elseif status == model.STATUS_UPDATE then
            buttons[#buttons + 1] = {kind = "update", key = "Enter", label = "Update", enabled = true, primary = true}
        else
            buttons[#buttons + 1] = {kind = "refresh", key = "Enter", label = "Check", enabled = true, primary = true}
        end
        if model.can_follow(row) and row then
            if status == model.STATUS_SHARED then
                buttons[#buttons + 1] = {kind = "install_follow", key = "F", label = "Install & follow", enabled = true}
            else
                local follows = row.follow_state == "following"
                buttons[#buttons + 1] = {kind = follows and "pause_follow" or "follow", key = "F", label = follows and "Pause updates" or "Follow source", enabled = true}
                buttons[#buttons + 1] = {kind = "pin_follow", key = "V", label = "Pin version", enabled = row.follow_state ~= "pinned"}
            end
        end
        buttons[#buttons + 1] = {kind = "technical", key = "T", label = state.governed.technical and "Hide technical" or "Technical", enabled = true}
        buttons[#buttons + 1] = {kind = "back", key = "Esc", label = "Back", enabled = true}
        if row and row.application and state.can_open then
            buttons[#buttons + 1] = {kind = "launch", key = "L", label = "Open", enabled = true}
        end
        if model.can_share(row) then buttons[#buttons + 1] = {kind = "share", key = "H", label = "Share with your hive", enabled = true} end
        if model.can_go_back(row) then buttons[#buttons + 1] = {kind = "go_back", key = "B", label = "Go back", enabled = true} end
        if model.can_remove(row) then buttons[#buttons + 1] = {kind = "remove", key = "X", label = "Remove", enabled = true} end
        if state.governed.technical then
            local item = governed.selected(state.governed)
            buttons[#buttons + 1] = {kind = "accept", label = "Accept", enabled = governed.accepts_review(item)}
            buttons[#buttons + 1] = {kind = "reject", label = "Reject", enabled = governed.accepts_review(item)}
            buttons[#buttons + 1] = {kind = "select", label = "Select", enabled = governed.can_select(item)}
            buttons[#buttons + 1] = {kind = "prepare", label = "Prepare", enabled = governed.can_prepare(state.governed, item)}
            buttons[#buttons + 1] = {kind = "step", label = "Apply", enabled = governed.can_advance(state.governed)}
            buttons[#buttons + 1] = {kind = "status", label = "Status", enabled = state.governed.intent ~= nil}
            buttons[#buttons + 1] = {kind = "recover", label = "Recover", enabled = item ~= nil}
        end
        return buttons
    end
    local tab = state.tab
    if tab == "installed" then
        if row and row.status == model.STATUS_UPDATE then
            buttons[#buttons + 1] = {kind = "update", key = "U", label = "Update", enabled = true, primary = true}
        end
        local own = row ~= nil and row.origin == "governed"
        local launchable = own and row ~= nil and row.application ~= nil and state.can_open
        local updating = row ~= nil and row.status == model.STATUS_UPDATE
        if row ~= nil and row.kind == "platform" then
            buttons[#buttons + 1] = {kind = "platform", key = "Enter", label = "Packages", enabled = true, primary = not updating}
        elseif own then
            buttons[#buttons + 1] = {kind = "launch", key = "Enter", label = "Open", enabled = launchable, primary = launchable and not updating}
            buttons[#buttons + 1] = {kind = "open", key = "D", label = "Details", enabled = true, primary = not launchable and not updating}
            if row ~= nil and row.made_here then
                buttons[#buttons + 1] = {kind = "share", key = "H", label = "Share with your hive", enabled = model.can_share(row)}
            end
            buttons[#buttons + 1] = {kind = "go_back", key = "B", label = "Go back", enabled = model.can_go_back(row)}
            buttons[#buttons + 1] = {kind = "remove", key = "X", label = "Remove", enabled = model.can_remove(row)}
        else
            buttons[#buttons + 1] = {kind = "open", key = "Enter", label = "Details", enabled = row ~= nil, primary = not updating}
            buttons[#buttons + 1] = {kind = "remove", key = "X", label = "Remove", enabled = model.can_remove_package(row)}
        end
    elseif tab == "shared" then
        if row ~= nil and row.kind == "section" then
            buttons[#buttons + 1] = {kind = "hub_catalog", key = "Enter", label = "Browse", enabled = true, primary = true}
        else
            buttons[#buttons + 1] = {kind = "install", key = "Enter", label = "Install", enabled = row ~= nil, primary = true}
            buttons[#buttons + 1] = {kind = "open", key = "O", label = "Open", enabled = row ~= nil}
        end
    else
        local operation: hub.Operation? = nil
        for _, candidate in ipairs(state.hub.operations) do
            if row and candidate.digest == row.operation then operation = candidate end
        end
        buttons[#buttons + 1] = {kind = "technical", key = "T", label = state.governed.technical and "Hide technical" or "Technical", enabled = true}
        buttons[#buttons + 1] = {kind = "operations_previous", label = "Prev", enabled = state.hub.operation_page > 1}
        buttons[#buttons + 1] = {kind = "operations_next", label = "Next",
            enabled = state.hub.operation_page < math.max(1, math.ceil(state.hub.operation_total / math.max(1, state.hub.operation_page_size)))}
        if operation and operation.request and (operation.state == "prepared" or operation.state == "published" or operation.state == "recovery_required") then
            buttons[#buttons + 1] = {kind = "recover", key = "G", label = "Finish change", enabled = true, primary = true}
        end
    end
    if tab == "shared" and with_filters then
        for _, button in ipairs(filters(state)) do buttons[#buttons + 1] = button end
    end
    if tab ~= "history" then buttons[#buttons + 1] = {kind = "technical", key = "T", label = state.governed.technical and "Hide technical" or "Technical", enabled = true} end
    buttons[#buttons + 1] = {kind = "refresh", key = "R", label = "Refresh", enabled = true}
    return buttons
end

local function lines_of(state: model.State, row: model.Row): {string}
    local lines: {string} = {}
    if row.origin == "governed" and state.tab == "history" then
        lines[#lines + 1] = "Status   " .. row.status .. (row.replaced_by and (" by " .. row.replaced_by) or "") .. (row.note ~= "" and (" · " .. row.note) or "")
        lines[#lines + 1] = "Source   " .. row.source
        if state.governed.technical then
            for _, item in ipairs(state.governed.activations) do
                if item.intent_id == row.intent_id then
                    lines[#lines + 1] = "Activation " .. item.phase .. (item.outcome and ("  " .. item.outcome) or "") .. "  " .. item.intent_id
                    if item.diagnostics and item.diagnostics ~= "" then lines[#lines + 1] = item.diagnostics end
                end
            end
        end
        return lines
    end
    if row.origin == "hub" and state.tab == "history" then
        for _, operation in ipairs(state.hub.operations) do
            if operation.digest == row.operation then
                return hub_view.receipt_lines(operation, state.governed.technical)
            end
        end
    end
    return lines
end

-- The row's cells: name, version, status with the newer version it offers,
-- and where it came from.
local function cells(row: model.Row): {string}
    local status = row.kind == "section" and "" or (model.status_glyph(row.status) .. " " .. row.status .. (row.update and (" " .. row.update) or "") .. (row.replaced_by and (" by " .. row.replaced_by) or ""))
    local source = row.source
    if row.note ~= "" then source = source .. " · " .. row.note end
    return {model.kind_glyph(row.kind) .. " " .. row.name, row.version, status, source}
end

local COLUMNS: {frame.Column} = {{title = "Name", width = 0}, {title = "Version", width = 14},
    {title = "Status", width = 28}, {title = "Source", width = 34}}

local function empty_title(state: model.State): (string, string)
    local tab = state.tab
    if tab == "shared" and #(state.hub.all_catalog or {}) > 0 then
        return "Only developer packages are shared", "Developer packages are hidden · enable Developer packages to show them"
    end
    if tab == "installed" then return "Nothing installed yet", "Install something from Shared · Tab change view" end
    if tab == "shared" then return "Nothing is shared with this bee", "Versions other bees and the Hub share appear here · R refresh" end
    return "No history yet", "Installs and removals appear here"
end

local function draw_list(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, ui: Ui): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    frame.header(painter, "LIBRARY", model.summary(state))
    if height >= 6 then frame.tabs(painter, 2, TABS, "tab_" .. state.tab) end
    local rows = model.rows(state)
    local chosen = model.selected_row(state)
    local selected_index = 0
    local table_cells: {{string}} = {}
    local keys: {string} = {}
    for index, row in ipairs(rows) do
        table_cells[index] = cells(row)
        keys[index] = row.key
        if chosen and row.key == chosen.key then selected_index = index end
    end
    local status_y = height - 1
    local detail_lines: {string} = {}
    if chosen and state.tab == "history" and height >= 16 then detail_lines = lines_of(state, chosen) end
    local pane = math.min(#detail_lines, math.floor(math.max(3, (height - 10) // 2)))
    local last = status_y - (pane > 0 and pane + 2 or 1)
    local roomy = height >= 12
    if state.tab == "shared" and roomy then
        local x = 2
        for _, button in ipairs(filters(state)) do
            x = frame.button(painter, x, 3, {kind = button.kind, label = button.label, enabled = button.enabled, active = button.active})
        end
    end
    local window = {offset = 0, capacity = 0}
    if #rows == 0 then
        local title, action = empty_title(state)
        frame.empty(painter, 4, title, height >= 8 and action or nil)
    elseif height >= 6 then
        window = frame.table(painter, 4, last, {columns = COLUMNS, cells = table_cells, keys = keys, kind = "row",
            selected = selected_index, offset = ui.offset})
    end
    local detail_offset = 0
    if pane > 0 then
        frame.section(painter, status_y - pane - 1, "Selected", chosen and chosen.name or nil)
        detail_offset = math.floor(math.max(0, math.min(math.max(0, #detail_lines - pane), state.hub.operation_detail_offset)))
        for slot = 1, pane do
            local line = detail_lines[detail_offset + slot]
            if line then frame.line(painter, status_y - pane - 1 + slot, "  " .. text.bound(line, 8192), theme.text) end
        end
    end
    if height >= 4 then frame.actions(painter, status_y, M.actions(state, chosen, not roomy)) end
    frame.footer(painter, text.bound(ui.status ~= "" and ui.status or state.notice, 8192), HINTS,
        state.governed.technical and TECHNICAL_HINTS or nil)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter),
        capacity = window.capacity, offset = window.offset, operation_detail_offset = detail_offset}
end

-- draw_platform lists the packages the one Bee row stands for.
local function draw_platform(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, ui: Ui): Frame
    local painter = frame.new(width, height, preferences)
    local rows = model.platform(state)
    local chosen = model.selected_row(state)
    frame.header(painter, "LIBRARY  BEE", tostring(#rows) .. " packages · built in")
    if height >= 6 then frame.tabs(painter, 2, TABS, "tab_" .. state.tab) end
    local selected_index = 0
    local table_cells: {{string}} = {}
    local keys: {string} = {}
    for index, row in ipairs(rows) do
        table_cells[index] = {glyphs.package .. " " .. row.name, row.version, row.source}
        keys[index] = row.key
        if chosen and row.key == chosen.key then selected_index = index end
    end
    local window = {offset = 0, capacity = 0}
    if #rows > 0 and height >= 6 then
        window = frame.table(painter, 4, height - 2, {columns = {{title = "Package", width = 0}, {title = "Version", width = 14},
            {title = "Part of", width = 12}}, cells = table_cells, keys = keys, kind = "row", selected = selected_index, offset = ui.offset})
    end
    if height >= 4 then
        frame.actions(painter, height - 1, {{kind = "open", key = "Enter", label = "Details", enabled = chosen ~= nil, primary = true},
            {kind = "back", key = "Esc", label = "Back", enabled = true}})
    end
    frame.footer(painter, text.bound(ui.status ~= "" and ui.status or state.notice, 8192), HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter),
        capacity = window.capacity, offset = window.offset, operation_detail_offset = 0}
end

local function draw_version(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, ui: Ui): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local row = model.selected_row(state)
    frame.header(painter, "LIBRARY  " .. string.upper(row and row.name or "VERSION"), row and row.version or "")
    if height >= 6 then frame.tabs(painter, 2, TABS, "tab_" .. state.tab) end
    local status_y = height - 1
    local laid: {{text: string, heading: boolean, summary: string?}} = {}
    if row then
        if state.governed.technical then
            local plan = governed.selected(state.governed)
            for index, line in ipairs(governed.review_rows(state.governed)) do
                if line.heading and index > 1 then laid[#laid + 1] = {text = "", heading = false} end
                laid[#laid + 1] = {text = line.text, heading = line.heading, summary = line.summary}
            end
            if not plan then
                for _, item in ipairs(state.governed.available) do
                    if governed.available_key(item) == row.available_key then
                        laid[#laid + 1] = {text = "Descriptor " .. item.descriptor_digest, heading = false}
                        laid[#laid + 1] = {text = "Source " .. item.source_workspace .. " · " .. item.owner_id, heading = false}
                    end
                end
            end
            if state.governed.fault ~= "" then laid[#laid + 1] = {text = "Last result: " .. state.governed.fault, heading = false} end
        else
            laid[#laid + 1] = {text = row.name .. "  " .. row.version, heading = true}
            for _, line in ipairs(model.version_lines(state, row)) do
                laid[#laid + 1] = {text = frame.pad(line.label, 9) .. line.value, heading = false}
            end
        end
    else
        laid[#laid + 1] = {text = "Nothing is chosen", heading = false}
    end
    local first = 4
    local room = math.floor(math.max(0, status_y - first))
    local offset = math.floor(math.max(0, math.min(math.max(0, #laid - room), ui.offset)))
    for slot = 1, room do
        local line = laid[offset + slot]
        if not line then break end
        local y = first + slot - 1
        if line.heading then frame.section(painter, y, text.bound(line.text, 8192), line.summary and text.bound(line.summary, 8192) or nil)
        elseif line.text ~= "" then frame.line(painter, y, "  " .. text.bound(line.text, 8192), theme.text) end
    end
    if height >= 4 then frame.actions(painter, status_y, M.actions(state, row)) end
    frame.footer(painter, text.bound(ui.status ~= "" and ui.status or state.notice, 8192), HINTS,
        state.governed.technical and TECHNICAL_HINTS or nil)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter),
        capacity = room, offset = offset, operation_detail_offset = 0}
end

-- draw_removal floats the removal's confirmation above a drawn screen and
-- takes every click for itself.
local function draw_removal(base: Frame, width: integer, height: integer, preferences: appearance.Preferences, removal: model.Removal): Frame
    local painter = frame.new(width, height, preferences)
    for y, row in ipairs(base.rows) do painter.canvas:put(1, y, row, width) end
    local lines = model.removal_lines(removal)
    local box = frame.modal(painter, math.min(76, width - 2), #lines + 5, removal.kind == "back" and "Go back" or "Remove")
    if box.width > 0 then
        for index, line in ipairs(lines) do
            frame.put(painter, box.x, box.y + index, text.bound(line, 8192), box.width, index == 1 and painter.theme.accent or painter.theme.text)
        end
        local x = box.x
        local y = box.y + #lines + 2
        x = frame.button(painter, x, y, {kind = "confirm_remove", key = "Enter", label = removal.kind == "back" and "Go back" or "Remove", enabled = true, primary = true})
        frame.button(painter, x, y, {kind = "cancel_remove", key = "Esc", label = "Keep", enabled = true})
    end
    return {rows = frame.rows(painter), hits = painter.hits, controls = nil, capacity = base.capacity,
        offset = base.offset, operation_detail_offset = base.operation_detail_offset}
end

-- draw paints the screen the model is on, with an open editor floating above it.
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, ui: Ui): Frame
    local screen = M.screen(state)
    local base: Frame
    if screen == "package" then
        base = hub_view.draw(width, height, preferences, state.hub, ui.offset, ui.editor and "" or ui.status, ui.reading, nil, ui.content,
            {tabs = TABS, active = "tab_" .. state.tab, technical = state.governed.technical})
    elseif screen == "version" then base = draw_version(width, height, preferences, state, ui)
    elseif screen == "platform" then base = draw_platform(width, height, preferences, state, ui)
    else base = draw_list(width, height, preferences, state, ui) end
    local editor = ui.editor
    if editor then return hub_view.overlay(base, width, height, preferences, ui.status, editor) end
    local removal = state.removal
    if removal then return draw_removal(base, width, height, preferences, removal) end
    return base
end

return M

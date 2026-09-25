-- MIT. The Workspaces frame: the search field, one page of the catalog and,
-- from the standard size class, the selected workspace's detail beside it.
-- On compact and narrow canvases Enter opens the detail as its own page. The
-- create flow is a two-step wizard over the same frame. Every text arrives
-- bounded by the model.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
local creation = require("creation")
local folder_picker = require("folder_picker")
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local M = {}

-- Every action's key, in bar order; wider canvases also name the tab switch.
local HINTS = frame.hints({{key = "↑↓", verb = "move"}, {key = "Enter", verb = "open"}, {key = "N", verb = "new"}, {key = "/", verb = "search"},
    {key = "S", verb = "serve"}, {key = "A", verb = "archive"}, {key = "Esc", verb = "close"}})
local WIDE_HINTS = frame.hints({{key = "↑↓", verb = "move"}, {key = "PgUp PgDn", verb = "page"}, {key = "Enter", verb = "open"},
    {key = "N", verb = "new"}, {key = "/", verb = "search"}, {key = "Tab", verb = "switch"}, {key = "R", verb = "refresh"},
    {key = "S", verb = "serve"}, {key = "A", verb = "archive"}, {key = "Esc", verb = "close"}})
local EDIT_HINTS = frame.hints({{key = "Enter", verb = "search"}, {key = "Esc", verb = "stop editing"}})
local FOLDER_HINTS = frame.hints({{key = "↑↓", verb = "move"}, {key = "Enter", verb = "open"}, {key = "U", verb = "use folder"},
    {key = "⌫", verb = "up"}, {key = "Esc", verb = "cancel"}})
local DETAIL_HINTS = frame.hints({{key = "↑↓", verb = "field"}, {key = "Enter", verb = "create"}, {key = "Esc", verb = "back"}})

local function summary(state: model.State): string
    local noun = #state.items == 1 and " workspace" or " workspaces"
    local text = (state.tab == "archived" and "Archived" or "Active") .. " · page " .. tostring(state.page) .. " · "
        .. tostring(#state.items) .. noun
    if state.served then text = "Serving " .. model.label(state, state.served) .. " · " .. text end
    return text
end

-- One titled part of the detail from row y: the count on the title row, then
-- its items or the reason it could not be read. Returns the next free row.
local function section(painter: frame.Painter, rect: frame.Rect, y: integer, title: string, note: string, lines: {model.Item},
    fault: string?): integer
    local last = rect.y + rect.height - 1
    if y > last then return y end
    local theme = painter.theme
    local body = frame.panel(painter, {x = rect.x, y = y, width = rect.width, height = last - y + 1}, title, note)
    y = body.y
    if fault then
        if y <= last then frame.put(painter, rect.x, y, fault, rect.width, theme.error) end
        return y + 2
    end
    if #lines == 0 and y <= last then
        frame.put(painter, rect.x, y, "None", rect.width, theme.muted)
        y = y + 1
    end
    for _, item in ipairs(lines) do
        if y > last then return y end
        local drawn = frame.put(painter, rect.x, y, item.label, rect.width, theme.text)
        if item.detail ~= "" and drawn + 3 < rect.width then
            frame.put(painter, rect.x + drawn + 1, y, "· " .. item.detail, rect.width - drawn - 1, theme.muted)
        end
        y = y + 1
    end
    return y + 1
end

-- The selected workspace: its identity and folder, whether a host serves
-- it, then what it holds.
local function detail(painter: frame.Painter, rect: frame.Rect, state: model.State)
    local theme = painter.theme
    local selected = model.selected(state)
    if rect.width <= 0 or rect.height <= 0 then return end
    if not selected then
        frame.empty(painter, rect.y, "No workspace selected", "↑↓ select a workspace", rect)
        return
    end
    local shown = state.detail
    local live = shown and shown.workspace_id == selected.workspace_id and shown.live
    local state_word = selected.state == "archived" and "Archived" or (live and "Served" or "Not served")
    local body = frame.panel(painter, rect, selected.label ~= "" and selected.label or "Unnamed workspace", state_word)
    local last = body.y + body.height - 1
    local y = body.y
    local function field(label: string, value: string)
        if y > last then return end
        frame.put(painter, body.x, y, frame.pad(label, 9), 9, theme.muted)
        frame.put(painter, body.x + 9, y, value, body.width - 9, theme.text)
        y = y + 1
    end
    field("Folder", model.folder(selected))
    field("Used", selected.last_used_at)
    field("Created", selected.created_at)
    field("ID", selected.workspace_id)
    y = y + 1
    if not shown or shown.workspace_id ~= selected.workspace_id then
        if y <= last then frame.empty(painter, y, "Loading what this workspace holds", "R refresh", {x = body.x, y = y, width = body.width, height = last - y + 1}) end
        return
    end
    if shown.error then
        frame.empty(painter, y, "Could not inspect this workspace", shown.error, {x = body.x, y = y, width = body.width, height = last - y + 1})
        return
    end
    local area: frame.Rect = {x = body.x, y = y, width = body.width, height = last - y + 1}
    y = section(painter, area, y, "Applications", tostring(#shown.applications), shown.applications, nil)
    area = {x = body.x, y = y, width = body.width, height = last - y + 1}
    y = section(painter, area, y, "Threads", tostring(#shown.threads) .. (shown.more_threads and "+" or ""), shown.threads, shown.threads_error)
    for _, part in ipairs(shown.sections) do
        area = {x = body.x, y = y, width = body.width, height = last - y + 1}
        y = section(painter, area, y, part.title, part.error and "" or tostring(part.total), part.items, part.error)
    end
end

local function list(painter: frame.Painter, rect: frame.Rect, state: model.State, offset: integer, focused: boolean): frame.Window
    if state.error and #state.items == 0 then
        frame.empty(painter, rect.y, "Could not read the workspace catalog", state.error .. " · R retry", rect)
        return {offset = 0, capacity = 0}
    end
    if #state.items == 0 then
        local title = state.query ~= "" and "No workspace matches " .. state.query or
            (state.tab == "archived" and "No archived workspaces" or "No workspaces yet")
        frame.empty(painter, rect.y, title, state.query ~= "" and "/ change the search" or "Tab switch", rect)
        return {offset = 0, capacity = 0}
    end
    local cells: {{string}} = {}
    local keys: {string} = {}
    local selected_index = 0
    for index, item in ipairs(state.items) do
        cells[index] = {item.label ~= "" and item.label or "Unnamed", model.folder(item), item.last_used_at:sub(1, 10)}
        keys[index] = item.workspace_id
        if item.workspace_id == state.selected then selected_index = index end
    end
    local columns: {frame.Column} = {{title = "Workspace", width = 0}}
    if rect.width >= 60 then
        columns[#columns + 1] = {title = "Folder", width = math.floor(math.min(32, rect.width // 3))}
        columns[#columns + 1] = {title = "Used", width = 10}
    end
    local visible: {{string}} = {}
    for index, row in ipairs(cells) do visible[index] = columns[2] and row or {row[1]} end
    return frame.table(painter, rect.y, rect.y + rect.height - 1, {columns = columns, cells = visible, keys = keys, kind = "workspace",
        selected = selected_index, offset = offset, focused = focused, area = rect})
end

-- The details step: the folder the workspace will hold, its label and, under
-- a root admitted for writing, the new folder made inside the chosen one.
local function details(painter: frame.Painter, rect: frame.Rect, form: creation.Form)
    local theme = painter.theme
    local writable = creation.writable(form)
    local width = writable and 10 or 5
    local y = rect.y
    local last = rect.y + rect.height - 1
    if y <= last then
        frame.field(painter, y, "Label", form.label .. (form.field == 1 and "▏" or ""), width, form.field == 1, 1,
            form.field == 1 and form.failure or nil)
        y = y + 1
    end
    if writable and y <= last then
        local shown = form.new_folder .. (form.field == 2 and "▏" or "")
        frame.field(painter, y, "New folder", shown, width, form.field == 2, 2, form.field == 2 and form.failure or nil)
        if form.new_folder == "" and form.field ~= 2 then
            frame.put(painter, 2 + width + 2, y, "optional, made inside the folder", rect.width - width - 2, theme.muted)
        end
        y = y + 1
    end
    y = y + 1
    if y <= last then
        local location = folder_picker.location(form.picker)
        if writable and form.new_folder ~= "" then location = location .. "/" .. form.new_folder end
        frame.put(painter, rect.x, y, frame.pad("Holds", width), width, theme.muted)
        frame.put(painter, rect.x + width + 2, y, location, rect.width - width - 2, theme.text)
    end
end

local function draw_create(painter: frame.Painter, form: creation.Form, offset: integer): Frame
    local theme = painter.theme
    local layout = frame.layout(painter, false, true)
    local location = folder_picker.location(form.picker)
    frame.header(painter, "NEW WORKSPACE", location ~= "" and location or "Choose a root")
    local work = layout.work
    if work.y > 2 then frame.steps(painter, 2, {"Folder", "Details"}, form.step == "details" and 2 or 1) end
    local window: frame.Window = {offset = 0, capacity = 0}
    if work.height >= 1 then
        frame.put(painter, work.x, work.y, "Folder", 6, theme.muted)
        local held = form.picker.held and " · a workspace already" or ""
        frame.put(painter, work.x + 8, work.y, (location ~= "" and location or "Choose a root") .. held, work.width - 8, theme.text)
    end
    local body: frame.Rect = {x = work.x, y = work.y + 2, width = work.width, height = math.floor(math.max(0, work.height - 2))}
    if form.step == "details" then details(painter, body, form) else window = folder_picker.draw(painter, body, form.picker, offset, "U use this folder") end
    if layout.actions > 0 then
        if form.step == "details" then
            frame.actions(painter, layout.actions, {
                {kind = "create_submit", label = "Create", key = "Enter", enabled = true, primary = true},
                {kind = "create_back", label = "Back", key = "Esc", enabled = true},
            })
        else
            local picker = form.picker
            local count = picker.root and #picker.folders or #picker.roots
            frame.actions(painter, layout.actions, {
                {kind = "create_open", label = "Open", key = "Enter", enabled = count > 0, primary = true},
                {kind = "create_use", label = "Use folder", key = "U", enabled = picker.root ~= nil},
                {kind = "create_up", label = "Up", key = "⌫", enabled = picker.root ~= nil},
                {kind = "create_cancel", label = "Cancel", key = "Esc", enabled = true},
            })
        end
    end
    local status = form.failure or ""
    frame.footer(painter, status, form.step == "details" and DETAIL_HINTS or FOLDER_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end

-- form: the create flow while it is open; it replaces the catalog screen.
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer,
    form: creation.Form?): Frame
    local painter = frame.new(width, height, preferences)
    if form then return draw_create(painter, form, offset) end
    local theme = painter.theme
    local layout = frame.layout(painter, true, true)
    frame.header(painter, "WORKSPACES", summary(state))
    if layout.tabs > 0 then
        frame.tabs(painter, layout.tabs, {{kind = "active", label = "Active"}, {kind = "archived", label = "Archived"}}, state.tab)
    end
    local work = layout.work
    local window: frame.Window = {offset = 0, capacity = 0}
    if work.height >= 1 then
        frame.field(painter, work.y, "Search", state.query .. (state.editing and "▏" or ""), 6, state.editing, 1)
        if state.query == "" and not state.editing then
            frame.put(painter, work.x + 8, work.y, "label prefix, or /folder", work.width - 8, theme.muted)
        end
    end
    local body: frame.Rect = {x = work.x, y = work.y + 2, width = work.width, height = math.floor(math.max(0, work.height - 2))}
    if layout.size == "standard" or layout.size == "wide" then
        local panes = frame.split(body, {layout.size == "wide" and 48 or 40, 0})
        window = list(painter, panes[1], state, offset, not state.editing)
        detail(painter, panes[2], state)
    elseif state.showing then
        detail(painter, body, state)
    else
        window = list(painter, body, state, offset, not state.editing)
    end
    if layout.actions > 0 then
        local selected = model.selected(state) ~= nil
        local archived = state.tab == "archived"
        frame.actions(painter, layout.actions, {
            {kind = "open", label = state.showing and "Back" or "Open", key = state.showing and "Esc" or "Enter", enabled = selected, primary = not state.confirming},
            {kind = "new", label = "New", key = "N", enabled = true},
            {kind = "search", label = "Search", key = "/", enabled = true},
            {kind = "refresh", label = "Refresh", key = "R", enabled = true},
            {kind = "serve", label = state.served and "Release" or "Serve", key = "S", enabled = (selected and not archived) or state.served ~= nil,
                active = state.served ~= nil},
            {kind = "change", label = archived and "Restore" or "Archive", key = "A", enabled = selected, primary = state.confirming},
        })
    end
    local status = state.status
    local hints = state.editing and EDIT_HINTS or (width >= 110 and WIDE_HINTS or HINTS)
    if state.confirming then
        local selected = model.selected(state)
        status = "Archive " .. (selected and (selected.label ~= "" and selected.label or selected.workspace_id) or "") .. "? Enter confirms · Esc cancels"
        hints = ""
    end
    frame.footer(painter, status, hints)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end

return M

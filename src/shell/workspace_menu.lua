-- SPDX-License-Identifier: MIT
-- The display's workspace menu, a dropdown under the bar's desktop label.
-- When the hive has more than one node, a strip of node tabs heads it: ←→ or
-- Tab browse another node's desktops and folders without leaving the node
-- this display shows. Below the strip it lists the browsed node's desktops
-- with a row to make a new one, then the folders that node works in with a
-- row to add one. Enter on a desktop shows it on this display (switching the
-- display to the browsed node) unless another display shows it; Enter on a
-- folder makes the shown desktop work there. On the shown node N makes a new
-- desktop, A adds a folder, R renames the selected desktop and X closes a
-- desktop or forgets a folder; / searches. The line above the footer names
-- the keys that act on the selected row. The menu holds only what the nodes
-- answered; every change is a request the shell sends to a node.
local tty = require("tty")
local appearance = require("appearance")
type Workspace = {id: string, path: string, label: string}
type Desktop = {id: string, title: string, workspace: string, shown: boolean}
-- A row is a desktop, a folder or one of the two actions that make a desktop
-- or add a folder.
type Row = {kind: "desktop" | "workspace" | "new_desktop" | "add_folder", desktop: Desktop?, workspace: Workspace?}
-- The desktops and folders are the browsed node's, counts how many apps each
-- of its desktops runs, and loaded whether that node has answered. nodes are
-- the hive's nodes, node the one this display shows, tab the one browsed and
-- labels the folder each node runs in, once known.
type Menu = {current: string, desktops: {Desktop}, workspaces: {Workspace}, counts: {[string]: integer}, loaded: boolean, rows: {Row},
    nodes: {string}, node: string, tab: string, labels: {[string]: string}, selected: integer, query: string, editing: boolean, status: string}
-- browse asks the shell for a node's catalog; switch names the desktop to
-- show, on node when the display moves to another node; use names the folder
-- for the shown desktop; create, rename, remove and add ask the shell for the
-- shown node's operation (rename and add first ask for text).
type Response = {close: boolean, browse: string?, node: string?, switch: string?, use: string?, create: boolean, rename: Desktop?,
    remove: Desktop?, add: boolean, forget: Workspace?}
-- body is the first row of the listed lines and capacity how many fit.
type Panel = {x: integer, y: integer, width: integer, height: integer, body: integer, capacity: integer}
-- A drawn line is a section heading, a row or the gap before a heading.
type Line = {heading: string?, row: integer?}
local M = {}
M.MAX_QUERY = 120
local WIDTH = 64
local TITLE_COLUMN = 16
local FOLDER_COLUMN = 14

local function none(): Response
    return {close = false, browse = nil, node = nil, switch = nil, use = nil, create = false, rename = nil, remove = nil, add = false,
        forget = nil}
end

local function workspace_of(menu: Menu, id: string): Workspace?
    for _, workspace in ipairs(menu.workspaces) do
        if workspace.id == id then return workspace end
    end
    return nil
end

local function matches(menu: Menu, text: string): boolean
    return menu.query == "" or text:lower():find(menu.query:lower(), 1, true) ~= nil
end

-- node_name is how the menu names a node: the folder it runs in, with its
-- identity only while that folder is unknown or another node shares it.
local function node_name(menu: Menu, node: string): string
    local label = menu.labels[node]
    if not label then return node end
    for _, other in ipairs(menu.nodes) do
        if other ~= node and menu.labels[other] == label then return label .. " (" .. node:sub(1, 12) .. ")" end
    end
    return label
end

-- shown reports whether the browsed node is the one this display shows.
local function shown(menu: Menu): boolean
    return menu.tab == menu.node
end

local function rebuild(menu: Menu)
    local rows: {Row} = {}
    for _, desktop in ipairs(menu.desktops) do
        local folder = workspace_of(menu, desktop.workspace)
        if matches(menu, desktop.title) or (folder ~= nil and matches(menu, folder.label)) then
            rows[#rows + 1] = {kind = "desktop", desktop = desktop, workspace = nil}
        end
    end
    if menu.query == "" and shown(menu) then rows[#rows + 1] = {kind = "new_desktop", desktop = nil, workspace = nil} end
    for _, workspace in ipairs(menu.workspaces) do
        if matches(menu, workspace.label) or matches(menu, workspace.path) then
            rows[#rows + 1] = {kind = "workspace", desktop = nil, workspace = workspace}
        end
    end
    if menu.query == "" and shown(menu) then rows[#rows + 1] = {kind = "add_folder", desktop = nil, workspace = nil} end
    menu.rows = rows
    menu.selected = math.floor(math.max(1, math.min(menu.selected, #rows)))
    menu.status = ""
    if not menu.loaded then menu.status = "Asking " .. node_name(menu, menu.tab) .. "…"
    elseif #rows == 0 then menu.status = menu.query ~= "" and "Nothing matches" or node_name(menu, menu.tab) .. " has no desktops" end
end

-- current_workspace is the folder the shown desktop works in, while the shown
-- node is browsed.
local function current_workspace(menu: Menu): string
    if not shown(menu) then return "" end
    for _, desktop in ipairs(menu.desktops) do
        if desktop.id == menu.current then return desktop.workspace end
    end
    return ""
end

function M.new(current: string, desktops: {Desktop}, workspaces: {Workspace}, counts: {[string]: integer},
    nodes: {string}, node: string): Menu
    -- The node tabs keep one order: the shown node first, the others by
    -- identity.
    local ordered: {string} = {node}
    local others: {string} = {}
    for _, item in ipairs(nodes) do
        if item ~= node then others[#others + 1] = item end
    end
    table.sort(others)
    for _, item in ipairs(others) do ordered[#ordered + 1] = item end
    local menu: Menu = {current = current, desktops = desktops, workspaces = workspaces, counts = counts, loaded = true, rows = {},
        nodes = ordered, node = node, tab = node, labels = {}, selected = 1, query = "", editing = false, status = ""}
    rebuild(menu)
    for index, row in ipairs(menu.rows) do
        if row.desktop and row.desktop.id == current then menu.selected = index end
    end
    return menu
end

local function row_key(row: Row?): string?
    if not row then return nil end
    return (row.desktop and row.desktop.id) or (row.workspace and row.workspace.id) or row.kind
end

-- update replaces node's catalog with its latest answer, keeping the
-- selection on the same row when it still exists; an answer from a node the
-- menu no longer browses is dropped.
function M.update(menu: Menu, node: string, desktops: {Desktop}, workspaces: {Workspace}, counts: {[string]: integer})
    if node ~= menu.tab then return end
    local keep = row_key(menu.rows[menu.selected])
    menu.desktops, menu.workspaces, menu.counts, menu.loaded = desktops, workspaces, counts, true
    rebuild(menu)
    for index, item in ipairs(menu.rows) do
        if keep and row_key(item) == keep then menu.selected = index end
    end
end

-- browse moves the node strip step tabs along and asks for that node's
-- catalog unless it is the node this display shows.
local function browse(menu: Menu, step: integer): string?
    if #menu.nodes < 2 then return nil end
    local at = 1
    for index, node in ipairs(menu.nodes) do
        if node == menu.tab then at = index end
    end
    local next_tab = menu.nodes[(at - 1 + step) % #menu.nodes + 1]
    menu.tab, menu.desktops, menu.workspaces, menu.counts, menu.loaded = next_tab, {}, {}, {}, false
    menu.selected, menu.query = 1, ""
    rebuild(menu)
    return next_tab
end

-- label records the folder node runs in.
function M.label(menu: Menu, node: string, label: string)
    menu.labels[node] = label
end

-- describe is the bar label of desktop id: its title and its folder.
function M.describe(desktops: {Desktop}, workspaces: {Workspace}, id: string): string?
    for _, desktop in ipairs(desktops) do
        if desktop.id == id then
            for _, workspace in ipairs(workspaces) do
                if workspace.id == desktop.workspace then return desktop.title .. " · " .. workspace.label end
            end
            return desktop.title
        end
    end
    return nil
end

local function move(menu: Menu, step: integer)
    if #menu.rows == 0 then return end
    menu.selected = math.floor(math.max(1, math.min(#menu.rows, menu.selected + step)))
end

function M.respond(menu: Menu, event: unknown): Response
    local response = none()
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return response end
    local kind = tostring(event.key_type or "")
    local key = tostring(event.key or "")
    local plain = event.ctrl ~= true and event.alt ~= true
    if menu.editing then
        if kind == "enter" or kind == "esc" or kind == "escape" then menu.editing = false
        elseif kind == "backspace" then
            menu.query = menu.query:sub(1, math.floor(math.max(0, #menu.query - 1)))
            rebuild(menu)
        elseif kind == "space" and plain and #menu.query < M.MAX_QUERY then
            menu.query = menu.query .. " "
            rebuild(menu)
        elseif kind == "runes" and key ~= "" and not key:find("%c") and plain and #menu.query + #key <= M.MAX_QUERY then
            menu.query = menu.query .. key
            rebuild(menu)
        end
        return response
    end
    local row = menu.rows[menu.selected]
    local here = shown(menu)
    if kind == "esc" or kind == "escape" then
        if menu.query ~= "" then
            menu.query = ""
            rebuild(menu)
        else response.close = true end
    elseif kind == "up" then move(menu, -1)
    elseif kind == "down" then move(menu, 1)
    elseif kind == "right" or (kind == "tab" and event.shift ~= true) then response.browse = browse(menu, 1)
    elseif kind == "left" or kind == "backtab" or (kind == "tab" and event.shift == true) then response.browse = browse(menu, -1)
    elseif kind == "home" then menu.selected = 1
    elseif kind == "end" then menu.selected = math.floor(math.max(1, #menu.rows))
    elseif key == "/" then menu.editing = true
    elseif (key == "a" or key == "A") and plain and here then response.add = true
    elseif (key == "n" or key == "N") and plain and here then response.create = true
    elseif (key == "r" or key == "R") and plain and here and row and row.desktop then response.rename = row.desktop
    elseif (key == "x" or key == "X") and plain and here and row and row.desktop then
        if row.desktop.id == menu.current then menu.status = "This display shows that desktop"
        else response.remove = row.desktop end
    elseif (key == "x" or key == "X") and plain and here and row and row.workspace then
        response.forget = row.workspace
    elseif kind == "enter" and row then
        if row.kind == "new_desktop" then response.create = true
        elseif row.kind == "add_folder" then response.add = true
        elseif row.desktop then
            if here and row.desktop.id == menu.current then response.close = true
            elseif row.desktop.shown then menu.status = row.desktop.title .. " is on another display"
            else
                response.close = true
                response.switch = row.desktop.id
                if not here then response.node = menu.tab end
            end
        elseif row.workspace then
            if not here then menu.status = "Show a desktop of " .. node_name(menu, menu.tab) .. " to work in its folders"
            else
                response.close = true
                if row.workspace.id ~= current_workspace(menu) then response.use = row.workspace.id end
            end
        end
    end
    return response
end

local function section_of(row: Row): string
    if row.kind == "desktop" or row.kind == "new_desktop" then return "desktop" end
    return "workspace"
end

-- lines lays the rows out under a heading per section, a gap between
-- sections: the hive's nodes, the shown node's desktops and its folders.
local function lines(menu: Menu): {Line}
    local laid: {Line} = {}
    local section = ""
    for index, row in ipairs(menu.rows) do
        local this = section_of(row)
        if this ~= section then
            if section ~= "" then laid[#laid + 1] = {heading = nil, row = nil} end
            section = this
            local heading = this == "desktop" and "DESKTOPS" or "FOLDERS"
            laid[#laid + 1] = {heading = heading, row = nil}
        end
        laid[#laid + 1] = {heading = nil, row = index}
    end
    return laid
end

-- searching reports whether the search line shows: while typing or while a
-- query filters the rows.
local function searching(menu: Menu): boolean
    return menu.editing or menu.query ~= ""
end

-- strip reports whether the node tabs show: when the hive has more than one
-- node.
local function strip(menu: Menu): boolean
    return #menu.nodes > 1
end

-- panel is the dropdown's frame for menu: as tall as its lines, within the
-- screen, at the right edge under the bar. The node tabs and the search
-- line, when they show, sit above the listed lines.
function M.panel(width: integer, height: integer, menu: Menu): Panel
    local w = math.floor(math.min(WIDTH, width - 2))
    local top = (strip(menu) and 2 or 0) + (searching(menu) and 1 or 0)
    -- Below the lines: a gap, the hints, the keys, and the bottom border.
    local wanted = 1 + top + #lines(menu) + 4
    local h = math.floor(math.max(8, math.min(wanted, height - 2)))
    local x = math.floor(math.max(1, width - w))
    return {x = x, y = 2, width = w, height = h, body = top + 1, capacity = math.floor(math.max(0, h - top - 5))}
end

function M.available(width: integer, height: integer): boolean return width >= 24 and height >= 8 end

-- offset is the first drawn line that keeps the selected row, and its
-- heading when there is room, in view.
local function offset(laid: {Line}, selected: integer, capacity: integer): integer
    local at = 1
    for index, line in ipairs(laid) do
        if line.row == selected then at = index end
    end
    if at <= capacity then return 0 end
    return at - capacity
end

-- row_at returns the row index drawn at (x, y).
function M.row_at(menu: Menu, width: integer, height: integer, x: integer, y: integer): integer?
    local panel = M.panel(width, height, menu)
    if x <= panel.x or x >= panel.x + panel.width - 1 then return nil end
    local drawn = y - panel.y - panel.body + 1
    if drawn < 1 or drawn > panel.capacity then return nil end
    local laid = lines(menu)
    local line = laid[offset(laid, menu.selected, panel.capacity) + drawn]
    if line and line.row then return line.row end
    return nil
end

function M.contains(width: integer, height: integer, menu: Menu, x: integer, y: integer): boolean
    local panel = M.panel(width, height, menu)
    return x >= panel.x and x < panel.x + panel.width and y >= panel.y and y < panel.y + panel.height
end

-- tab_at returns the node whose tab is drawn at column x on the strip row.
function M.tab_at(menu: Menu, width: integer, height: integer, x: integer, y: integer): string?
    local panel = M.panel(width, height, menu)
    if not strip(menu) or y ~= panel.y + 1 then return nil end
    local column = panel.x + 2
    for _, node in ipairs(menu.nodes) do
        local label = " " .. node_name(menu, node) .. " "
        local w = tty.text.width(label)
        if x >= column and x < column + w then return node end
        column = column + w + 1
    end
    return nil
end

-- choose browses node, as clicking its tab does.
function M.choose(menu: Menu, node: string): string?
    for index, item in ipairs(menu.nodes) do
        if item == node then
            local at = 1
            for position, current in ipairs(menu.nodes) do
                if current == menu.tab then at = position end
            end
            if index == at then return nil end
            return browse(menu, index - at)
        end
    end
    return nil
end

-- hints are the keys that act on the selected row.
local function hints(menu: Menu, row: Row?): string
    if not shown(menu) then
        if row and row.desktop and not row.desktop.shown then return "Enter show here (this display moves to " .. node_name(menu, menu.tab) .. ")" end
        if row and row.desktop then return "On another display" end
        return "Browsing " .. node_name(menu, menu.tab) .. " · Enter on a desktop shows it here"
    end
    if not row then return "N new desktop · A add folder" end
    if row.kind == "new_desktop" then return "Enter make a desktop on " .. node_name(menu, menu.node) end
    if row.kind == "add_folder" then return "Enter add a folder this node works in" end
    if row.desktop then
        if row.desktop.id == menu.current then return "Shown here · R rename" end
        if row.desktop.shown then return "On another display · R rename" end
        return "Enter show here · R rename · X close"
    end
    if row.workspace and row.workspace.id == current_workspace(menu) then return "This desktop works here · X forget" end
    return "Enter work here · X forget"
end

-- fit pads or cuts text to exactly width columns.
local function fit(text: string, width: integer): string
    if width <= 0 then return "" end
    local cut = tty.text.truncate(text, width, "…")
    return cut .. string.rep(" ", math.floor(math.max(0, width - tty.text.width(cut))))
end

-- tail keeps the end of path, where its folder name is, within width.
local function tail(path: string, width: integer): string
    if tty.text.width(path) <= width then return path end
    if width <= 1 then return "…" end
    local kept = path
    while tty.text.width(kept) > width - 1 do kept = kept:sub(2) end
    return "…" .. kept
end

function M.draw(canvas: tty.Canvas, width: integer, height: integer, preferences: appearance.Preferences, menu: Menu): ()
    if not M.available(width, height) then return end
    local theme = preferences.theme
    local normal = appearance.style(theme.text, theme.surface)
    local muted = appearance.style(theme.muted, theme.surface)
    local accent = appearance.style(theme.accent, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local chosen = appearance.style(appearance.selection_text(theme), theme.accent)
    local reset = "\27[0m"
    local panel = M.panel(width, height, menu)
    local inside = panel.width - 2
    local text_width = inside - 2
    for y = panel.y, panel.y + panel.height - 1 do
        local edge = y == panel.y or y == panel.y + panel.height - 1
        local row = "│" .. string.rep(" ", inside) .. "│"
        if edge then row = (y == panel.y and "╭" or "╰") .. string.rep("─", inside) .. (y == panel.y and "╮" or "╯") end
        canvas:put(panel.x, y, border .. row .. reset, panel.width)
    end
    canvas:put(panel.x + 2, panel.y, accent .. tty.text.truncate(" Bees ", inside - 2, "…") .. reset, inside - 2)
    local function put(line: integer, text: string, style: string)
        canvas:put(panel.x + 2, panel.y + line, style .. fit(text, text_width) .. reset, text_width)
    end
    -- A row's columns: its name, then a detail, then its state at the right.
    local function columns(name: string, detail: string, state: string): string
        local state_width = tty.text.width(state)
        local left = text_width - state_width - (state_width > 0 and 1 or 0)
        return fit(fit(name, math.floor(math.min(left, TITLE_COLUMN + 2))) .. detail, left) .. (state_width > 0 and " " .. state or "")
    end
    if strip(menu) then
        -- The node tabs: the browsed node raised, the shown node marked.
        local column = panel.x + 2
        local right = panel.x + panel.width - 2
        for _, node in ipairs(menu.nodes) do
            local label = " " .. node_name(menu, node) .. (node == menu.node and " ●" or "") .. " "
            local w = math.floor(math.min(tty.text.width(label), right - column))
            if w <= 0 then break end
            local style = node == menu.tab and chosen or muted
            canvas:put(column, panel.y + 1, style .. tty.text.truncate(label, w, "…") .. reset, w)
            column = column + w + 1
        end
        put(2, string.rep("─", text_width), border)
    end
    if searching(menu) then put(panel.body - 1, "Search: " .. menu.query .. (menu.editing and "▏" or ""), menu.editing and normal or muted) end
    local used = current_workspace(menu)
    local laid = lines(menu)
    local first = offset(laid, menu.selected, panel.capacity)
    for drawn = 1, panel.capacity do
        local line = laid[first + drawn]
        local at = panel.body + drawn - 1
        if line and line.heading then
            put(at, line.heading, accent)
        elseif line and line.row then
            local index = line.row
            local row = menu.rows[index]
            local text = ""
            local style = normal
            if row.kind == "new_desktop" then
                text, style = "+ New desktop", muted
            elseif row.kind == "add_folder" then
                text, style = "+ Add folder…", muted
            elseif row.desktop then
                local folder = workspace_of(menu, row.desktop.workspace)
                local apps = menu.counts[row.desktop.id] or 0
                local count = apps == 1 and "1 app" or tostring(apps) .. " apps"
                local here = shown(menu) and row.desktop.id == menu.current
                local elsewhere = row.desktop.shown and not here
                text = columns((here and "● " or "  ") .. row.desktop.title,
                    fit(count, 8) .. (folder and fit(folder.label, FOLDER_COLUMN) or ""),
                    here and "this display" or (elsewhere and "other display" or ""))
                if elsewhere then style = muted end
            elseif row.workspace then
                local in_use = row.workspace.id == used
                local name = (in_use and "✓ " or "  ") .. row.workspace.label
                local name_width = math.floor(math.min(TITLE_COLUMN + 2, text_width))
                text = fit(name, name_width) .. tail(row.workspace.path, text_width - name_width)
                if not in_use then style = muted end
            end
            put(at, text, index == menu.selected and chosen or style)
        end
    end
    put(panel.height - 3, menu.status ~= "" and menu.status or hints(menu, menu.rows[menu.selected]), menu.status ~= "" and accent or normal)
    put(panel.height - 2, strip(menu) and "←→ node · ↑↓ select · / search · Esc close" or "↑↓ select · / search · Esc close", muted)
end
return M

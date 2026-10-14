-- MIT. The keyboard and mouse guide: each tab lists its bindings in titled
-- groups. No processes or node authority.
local appearance = require("appearance")
local frame = require("frame")
local manuals = require("manuals")
local markdown = require("markdown")
local text = require("text")
type Pane = "desktop" | "windows" | "workspaces" | "mouse" | "manuals"
-- A binding belongs to a group, the section it is listed under.
type Binding = {key: string, action: string, group: string}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
type Manuals = {documents: {manuals.Document}, selected: integer, query: string, searching: boolean, opened: manuals.Document?, status: string}
local M = {}

local PANES: {Pane} = {"desktop", "windows", "workspaces", "mouse", "manuals"}
M.PANES = PANES
local TABS: {frame.Tab} = {{kind = "desktop", label = "Desktop", short = "Desk"}, {kind = "windows", label = "Windows", short = "Win"},
    {kind = "workspaces", label = "Bees", short = "Bees"}, {kind = "mouse", label = "Mouse", short = "Mouse"}, {kind = "manuals", label = "Agent manuals", short = "Manuals"}}
local HINTS = frame.hints({{key = "↑↓", verb = "scroll"}, {key = "Tab", verb = "switch"}})
local KEY_WIDTH = 14

type Bindings = {desktop: {Binding}, windows: {Binding}, workspaces: {Binding}, mouse: {Binding}}
local BINDINGS: Bindings = {
    desktop = {
        {group = "Start and switch", key = "F1", action = "Open or close the Start menu"},
        {group = "Start and switch", key = "F3", action = "Desktops, workspaces and hive nodes"},
        {group = "Start and switch", key = "F4", action = "Open the Needs you request"},
        {group = "Start and switch", key = "Alt+Tab", action = "Focus the next window"},
        {group = "Start and switch", key = "Alt+Shift+Tab", action = "Focus the previous window"},
        {group = "Display", key = "F12", action = "Reload this display"},
        {group = "Display", key = "Ctrl+Q", action = "Close this display; apps keep running"},
    },
    windows = {
        {group = "Focused window", key = "Ctrl+W", action = "Close the focused app"},
        {group = "Focused window", key = "F11", action = "Full pane or floating"},
        {group = "Focused window", key = "Alt+F9", action = "Minimize the focused window"},
        {group = "Text", key = "Esc", action = "Leave text selection or a window move"},
        {group = "Text", key = "Ctrl+C", action = "Copy the selected text"},
        {group = "Apps", key = "?", action = "An app's own help, in its footer"},
    },
    workspaces = {
        {group = "Choose", key = "Enter", action = "Show the node, desktop or workspace"},
        {group = "Choose", key = "/", action = "Search"},
        {group = "Choose", key = "Esc", action = "Close the menu"},
        {group = "Change", key = "N", action = "New desktop"},
        {group = "Change", key = "R", action = "Rename the selected desktop"},
        {group = "Change", key = "X", action = "Close a desktop or forget a workspace"},
        {group = "Change", key = "A", action = "Add a workspace folder"},
    },
    mouse = {
        {group = "Windows", key = "Left click", action = "Focus a window; use its title-bar controls"},
        {group = "Windows", key = "Drag title", action = "Move a window"},
        {group = "Windows", key = "Drag edge", action = "Resize a window"},
        {group = "Menus", key = "Right click", action = "Menu of a window, a tab or the desktop"},
        {group = "Menus", key = "Shift+Right", action = "Pass a right click inside a window to its app"},
        {group = "Menus", key = "Bar", action = "Start, tabs and the desktop label"},
    },
}

function M.bindings(pane: Pane): {Binding}
    if pane == "manuals" then return {} end
    if pane == "windows" then return BINDINGS.windows end
    if pane == "workspaces" then return BINDINGS.workspaces end
    if pane == "mouse" then return BINDINGS.mouse end
    return BINDINGS.desktop
end

-- lines lays pane's bindings out under a heading per group, a gap between
-- groups; each binding is its key, then its action.
function M.lines(pane: Pane): {frame.Line}
    local laid: {frame.Line} = {}
    local group = ""
    for _, binding in ipairs(M.bindings(pane)) do
        if binding.group ~= group then
            if group ~= "" then laid[#laid + 1] = {} end
            group = binding.group
            laid[#laid + 1] = {heading = group}
        end
        laid[#laid + 1] = {label = binding.key, value = binding.action, label_role = "text", role = "muted"}
    end
    return laid
end

-- capacity is the number of lines the work area shows.
function M.capacity(width: integer, height: integer): integer
    local painter = frame.new(width, height, appearance.defaults())
    local layout = frame.layout(painter, true, false)
    return math.floor(math.max(0, layout.work.height))
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, pane: Pane, offset: integer, browser: Manuals?): Frame
    local painter = frame.new(width, height, preferences)
    local layout = frame.layout(painter, true, false)
    frame.header(painter, "BEE KEYBOARD HELP")
    if layout.tabs > 0 then frame.tabs(painter, layout.tabs, TABS, pane) end
    if pane == "manuals" then
        local state = browser or {documents = {}, selected = 1, query = "", searching = false, status = ""}
        local buttons: {frame.Button} = {}
        local hints = frame.hints({{key = "↑↓", verb = state.opened and "scroll" or "select"}, {key = "PgUp/PgDn", verb = "page"}, {key = "Tab", verb = "switch"}, {key = "Esc", verb = state.opened and "list" or "back"}})
        if state.opened then
            local lines = markdown.lines(state.opened.content, layout.work.width)
            frame.document(painter, layout.work.y, layout.work.y + layout.work.height - 1, lines, offset, 0)
            frame.header(painter, "AGENT MANUALS", text.bound(state.opened.title, 240))
            buttons = {{kind = "manuals_back", key = "Esc", label = "List", enabled = true, primary = true}}
        else
            local documents = manuals.search(state.documents, state.query)
            frame.header(painter, "BEE KEYBOARD HELP", tostring(#documents) .. " manuals")
            local first = layout.work.y
            local capacity = layout.work.height
            if state.query ~= "" or state.searching then
                frame.field(painter, first, "Search", text.bound(state.query, 256) .. (state.searching and "▏" or ""), 6, state.searching, 0)
                first = first + 2; capacity = math.floor(math.max(0, capacity - 2))
            end
            local window = frame.window(#documents, capacity, state.selected, 0)
            for slot = 1, window.capacity do
                local index = window.offset + slot
                local document = documents[index]
                if not document then break end
                frame.row(painter, first + slot - 1, frame.tagged(width, text.bound(document.title, 240), document.topic), index == state.selected, "manual", index, "")
            end
            if #documents == 0 then frame.empty(painter, first, state.status ~= "" and state.status or "No matching manuals", "/ Search title and text") end
            buttons = {{kind = "manuals_open", key = "Enter", label = "Read", enabled = documents[state.selected] ~= nil, primary = true}, {kind = "manuals_search", key = "/", label = "Search", enabled = true}}
        end
        frame.footer(painter, state.status, hints, nil, buttons)
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
    end
    if layout.work.height > 0 then
        frame.document(painter, layout.work.y, layout.work.y + layout.work.height - 1, M.lines(pane), offset, KEY_WIDTH)
    end
    if layout.footer > 0 then frame.footer(painter, "", HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M

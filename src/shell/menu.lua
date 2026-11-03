-- One bounded Start panel. Its layout is used unchanged by drawing and input.
local frame = require("frame")
local model = require("model")
-- A menu an app is placed in, declared in the registry (bee.menu).
type Placement = {id: string, title: string, location: "start" | "desktop", order: integer}
type Descriptor = {definition_id: string, title: string, menus: {Placement}}
-- A desktop a window can move to.
type Destination = {id: string, title: string}
type Item = frame.MenuItem
type State = frame.PopupState
type Panel = frame.Panel
type Response = frame.PopupResponse
local M = {}
-- placed lists the menus declared for location, ordered, each with the apps
-- placed in it as items in catalog order.
local function placed(catalog: {Descriptor}?, location: string): {{menu: Placement, items: {Item}}}
    local groups: {{menu: Placement, items: {Item}}} = {}
    local by_id: {[string]: {menu: Placement, items: {Item}}} = {}
    for _, descriptor in ipairs(catalog or {}) do
        for _, placement in ipairs(descriptor.menus) do
            if placement.location == location then
                local group = by_id[placement.id]
                if not group then
                    group = {menu = placement, items = {}}
                    by_id[placement.id] = group
                    groups[#groups + 1] = group
                end
                group.items[#group.items + 1] = {label = descriptor.title, action = "open:" .. descriptor.definition_id, enabled = true}
            end
        end
    end
    table.sort(groups, function(a, b)
        if a.menu.order ~= b.menu.order then return a.menu.order < b.menu.order end
        return a.menu.id < b.menu.id
    end)
    return groups
end

function M.items(catalog: {Descriptor}?): {Item}
    local items: {Item} = {}
    local seen: {[string]: boolean} = {}
    for _, group in ipairs(placed(catalog, "start")) do
        for _, item in ipairs(group.items) do
            if not seen[item.action] then
                items[#items + 1] = item
                seen[item.action] = true
            end
        end
    end
    items[#items + 1] = {label = "Bees", shortcut = "F3", action = "workspaces", enabled = true, group = true}
    items[#items + 1] = {label = "Exit", shortcut = "Ctrl+Q", action = "quit", enabled = true, group = true}
    return items
end
local function descend(items: {Item}, path: {integer}?): {Item}
    for _, index in ipairs(path or {}) do
        local item = items[index]
        if item and item.children then items = item.children else break end
    end
    return items
end
function M.entries(state: State, scene: model.Scene, catalog: {Descriptor}?, destinations: {Destination}?): {Item}
    if state.kind == "window" then
        local moves: {Item} = {}
        for _, destination in ipairs(destinations or {}) do
            moves[#moves + 1] = {label = destination.title, action = "move:" .. destination.id, enabled = true}
        end
        for _, win in ipairs(scene.windows) do
            if win.id == state.target then
                return descend({
                    {label = "Restore", action = "restore", enabled = win.mode ~= "floating"},
                    {label = "Minimize", shortcut = "Alt+F9", action = "minimize", enabled = win.mode ~= "minimized"},
                    {label = win.mode == "fullscreen" and "Advanced: floating layout" or "Full-pane layout", shortcut = "F11", action = "fullscreen", enabled = win.mode ~= "minimized"},
                    {label = "Snap left", action = "snap_left", enabled = win.mode ~= "minimized", group = true},
                    {label = "Snap right", action = "snap_right", enabled = win.mode ~= "minimized"},
                    {label = "Collapse", action = "collapse", enabled = win.mode == "floating"},
                    {label = "Rename…", action = "rename", enabled = true, group = true},
                    {label = "Select text", action = "select_text", enabled = win.mode ~= "collapsed"},
                    {label = "Move to desktop", action = "group:move", enabled = #moves > 0, children = moves},
                    {label = "Accent", action = "group:accent", enabled = true, children = {
                        {label = "Theme default", action = "accent:", enabled = true},
                        {label = "Amber", action = "accent:amber", enabled = true},
                        {label = "Cyan", action = "accent:cyan", enabled = true},
                        {label = "Green", action = "accent:green", enabled = true},
                        {label = "Rose", action = "accent:rose", enabled = true},
                        {label = "Violet", action = "accent:violet", enabled = true},
                    }},
                    {label = "Close", shortcut = "Ctrl+W", action = "close", enabled = true, group = true},
                }, state.path)
            end
        end
        return {}
    elseif state.kind == "desktop" then
        local items: {Item} = {}
        for _, group in ipairs(placed(catalog, "desktop")) do
            for _, item in ipairs(group.items) do items[#items + 1] = item end
        end
        items[#items + 1] = {label = "New desktop", action = "new_desktop", enabled = true, group = #items > 0}
        items[#items + 1] = {label = "Bees…", shortcut = "F3", action = "workspaces", enabled = true}
        items[#items + 1] = {label = "Restore windows", action = "restore_all", enabled = #scene.windows > 0, group = true}
        items[#items + 1] = {label = "Reload desktop", shortcut = "F12", action = "rejoin", enabled = true}
        return items
    end
    local items = M.items(catalog)
    for _, index in ipairs(state.path or {}) do
        local item = items[index]
        if item and item.children then items = item.children else break end
    end
    return items
end
-- The Start panel opens under the bar at the left edge; the window and
-- desktop menus open where the pointer was. The panel never covers the bar.
function M.panel(width: integer, height: integer, items: {Item}, state: State?): Panel
    return frame.popup_panel(width, height, items, state or {selected = 1, offset = 0}, 35, height >= 4 and 2 or 1)
end
-- respond adds the shell's own keys to the shared popup's input: Ctrl+Q
-- quits, Ctrl+W closes the window and the window menu's shortcuts act.
function M.respond(state: State, panel: Panel, items: {Item}, event: unknown): Response
    if type(event) == "table" and event.type == "key" and event.action ~= "release" then
        local action = ""
        if event.ctrl == true and event.key == "q" then action = "quit"
        elseif event.ctrl == true and event.key == "w" and state.kind == "window" then action = "close"
        elseif event.key_type == "f12" then action = "rejoin"
        else
            local wanted = event.key_type == "f9" and event.alt == true and "minimize" or event.key_type == "f11" and "fullscreen" or ""
            for _, item in ipairs(items) do if wanted ~= "" and item.action == wanted and item.enabled then action = wanted end end
        end
        if action ~= "" then return {state = frame.popup_fit(state, panel, items), action = action, close = false} end
    end
    return frame.popup_respond(state, panel, items, event)
end
return M

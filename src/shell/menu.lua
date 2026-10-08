-- One bounded Start panel. Its layout is used unchanged by drawing and input.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
-- A menu an app is placed in, declared in the registry (bee.menu).
type Placement = {id: string, title: string, location: "start" | "desktop", order: integer}
type Descriptor = {definition_id: string, title: string, menus: {Placement}}
-- A desktop a window can move to.
type Destination = {id: string, title: string}
-- group marks the first item of a group; a rule separates it from the items above.
type Item = {label: string, action: string, enabled: boolean, shortcut: string?, children: {Item}?, group: boolean?}
type State = {selected: integer, offset: integer, kind: string?, target: string?, x: integer?, y: integer?, path: {integer}?}
type Panel = {x: integer, y: integer, width: integer, height: integer, capacity: integer, inset: integer}
type Response = {state: State, action: string, close: boolean}
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

-- items is the Start menu: the Start menus the installed apps are placed in,
-- then the workspace menu and then exit, each in its own group.
function M.items(catalog: {Descriptor}?): {Item}
    local items: {Item} = {}
    for _, group in ipairs(placed(catalog, "start")) do
        items[#items + 1] = {label = group.menu.title, action = "group:" .. group.menu.id, enabled = true, children = group.items}
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
-- lines lays items out as drawn rows: each item's index, with 0 for the rule
-- before an item that starts a group.
local function lines(items: {Item}): {integer}
    local laid: {integer} = {}
    for index, item in ipairs(items) do
        if item.group and index > 1 then laid[#laid + 1] = 0 end
        laid[#laid + 1] = index
    end
    return laid
end
-- line_of is the drawn row of item index.
local function line_of(laid: {integer}, index: integer): integer
    for line, item in ipairs(laid) do
        if item == index then return line end
    end
    return 1
end
function M.panel(width: integer, height: integer, items: {Item}, state: State?): Panel
    local y = height >= 4 and 2 or 1
    local inset = state and state.path and #state.path > 0 and 1 or 0
    local h = math.floor(math.max(1, math.min(#lines(items) + 2 + inset, height - y + 1)))
    local w = math.floor(math.min(35, width))
    local x = 1
    if state and state.kind then
        x = math.floor(math.max(1, math.min(state.x or 1, width - w + 1)))
        y = math.floor(math.max(1, math.min(state.y or y, height - h + 1)))
    end
    return {x = x, y = y, width = w, height = h, capacity = math.floor(math.max(0, h - 2 - inset)), inset = inset}
end
-- fit clamps the selection to items and scrolls the drawn rows (offset) to
-- keep it in view.
function M.fit(state: State, panel: Panel, items: {Item}): State
    local laid = lines(items)
    local selected = math.floor(math.max(1, math.min(#items, state.selected)))
    local offset = math.floor(math.max(0, math.min(state.offset, #laid - panel.capacity)))
    local line = line_of(laid, selected)
    if line <= offset then offset = line - 1 end
    if line > offset + panel.capacity then offset = math.floor(math.max(0, line - panel.capacity)) end
    return {selected = selected, offset = offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}
end
function M.move(state: State, step: integer, items: {Item}, panel: Panel): State
    if #items == 0 then return state end
    local index = state.selected
    for _ = 1, #items do
        index = (index - 1 + step + #items) % #items + 1
        if items[index].enabled then break end
    end
    return M.fit({selected = index, offset = state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
end
function M.hit(panel: Panel, state: State, x: integer, y: integer, items: {Item}): integer?
    if x <= panel.x or x >= panel.x + panel.width - 1 or y < panel.y + 1 + panel.inset or y >= panel.y + panel.height - 1 then return nil end
    local index = lines(items)[state.offset + y - panel.y - panel.inset]
    if index and index >= 1 then return index end
    return nil
end
function M.respond(state: State, panel: Panel, items: {Item}, event: unknown): Response
    local next_state = M.fit(state, panel, items)
    local action, close = "", false
    local function back()
        local path: {integer} = {}
        for _, index in ipairs(next_state.path or {}) do path[#path + 1] = index end
        if #path == 0 then close = true; return end
        local selected = table.remove(path)
        next_state = {selected = selected or 1, offset = 0, path = path, kind = state.kind, target = state.target, x = state.x, y = state.y}
    end
    local function activate(index: integer)
        local item = items[index]
        if not item or not item.enabled then return end
        if item.children then
            local path: {integer} = {}
            for _, parent in ipairs(next_state.path or {}) do path[#path + 1] = parent end
            path[#path + 1] = index
            next_state = {selected = 1, offset = 0, path = path, kind = state.kind, target = state.target, x = state.x, y = state.y}
        else action = item.action end
    end
    if type(event) == "table" then
        if event.type == "key" and event.action ~= "release" then
            if event.ctrl == true and event.key == "q" then action = "quit"
            elseif event.ctrl == true and event.key == "w" and state.kind == "window" then action = "close"
            elseif event.key_type == "up" then next_state = M.move(next_state, -1, items, panel)
            elseif event.key_type == "down" or event.key_type == "tab" then next_state = M.move(next_state, 1, items, panel)
            elseif event.key_type == "pgup" or event.key_type == "pgdown" then
                local direction = event.key_type == "pgup" and -1 or 1
                local index = math.floor(math.max(1, math.min(#items, next_state.selected + direction * math.max(1, panel.capacity))))
                next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
                if items[index] and not items[index].enabled then next_state = M.move(next_state, direction, items, panel) end
            elseif event.key_type == "home" then next_state = M.fit({selected = 1, offset = 0, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
            elseif event.key_type == "end" then next_state = M.fit({selected = #items, offset = 0, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
            elseif event.key_type == "enter" then
                activate(next_state.selected)
            elseif event.key_type == "right" then
                local item = items[next_state.selected]
                if item and item.children then activate(next_state.selected) end
            elseif event.key_type == "left" or event.key_type == "backspace" then back()
            elseif event.key_type == "f9" and event.alt == true then
                for _, item in ipairs(items) do if item.action == "minimize" and item.enabled then action = "minimize" end end
            elseif event.key_type == "f12" then action = "rejoin"
            elseif event.key_type == "f11" then
                for _, item in ipairs(items) do if item.action == "fullscreen" and item.enabled then action = "fullscreen" end end
            elseif event.key_type == "esc" or event.key_type == "escape" then
                back()
            end
        elseif event.type == "mouse" and type(event.x) == "number" and type(event.y) == "number" then
            local x, y = math.floor(event.x), math.floor(event.y)
            local index = M.hit(panel, next_state, x, y, items)
            if event.action == "motion" and index and items[index].enabled then
                next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind,
                    target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
            elseif event.action == "wheel" then
                local up = event.button == "wheel_up" or event.button == "up"
                next_state = M.move(next_state, up and -1 or 1, items, panel)
            elseif event.action == "press" and event.button == "right" then
                close = true
            elseif event.action == "press" and event.button == "left" then
                if panel.inset > 0 and y == panel.y + 1 and x > panel.x and x < panel.x + panel.width - 1 then back()
                elseif index and items[index].enabled then
                    next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, items)
                    activate(index)
                elseif x < panel.x or x >= panel.x + panel.width or y < panel.y or y >= panel.y + panel.height then close = true end
            end
        end
    end
    return {state = next_state, action = action, close = close}
end
function M.draw(canvas: tty.Canvas, panel: Panel, state: State, items: {Item}, preferences: appearance.Preferences): ()
    local theme = preferences.theme
    local normal = appearance.style(theme.text, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local inside = math.floor(math.max(0, panel.width - 2))
    for y = panel.y, panel.y + panel.height - 1 do
        local edge = y == panel.y or y == panel.y + panel.height - 1
        local row = "│" .. string.rep(" ", inside) .. "│"
        if edge then row = (y == panel.y and "╭" or "╰") .. string.rep("─", inside) .. (y == panel.y and "╮" or "╯") end
        canvas:put(panel.x, y, border .. row .. "\27[0m", panel.width)
    end
    if panel.height < 3 or panel.width < 4 then return end
    if panel.inset > 0 then
        canvas:put(panel.x + 1, panel.y + 1, appearance.style(theme.muted, theme.surface) .. " ‹ Back\27[0m", inside)
    end
    local laid = lines(items)
    local muted = appearance.style(theme.muted, theme.surface)
    for row = 1, panel.capacity do
        local index = laid[state.offset + row]
        local item = index and items[index]
        local y = panel.y + panel.inset + row
        if index == 0 then
            canvas:put(panel.x, y, border .. "├" .. string.rep("─", inside) .. "┤\27[0m", panel.width)
        elseif index and item then
            local style = item.enabled and normal or muted
            local hint_style = muted
            if index == state.selected and item.enabled then
                style = appearance.style(appearance.selection_text(theme), appearance.selection_background(theme))
                hint_style = style
            end
            local available = math.floor(math.max(0, inside - 2))
            local hint = item.children and "›" or (item.shortcut or "")
            if tty.text.width(hint) + 4 > available then hint = "" end
            local hint_width = tty.text.width(hint)
            local label = tty.text.truncate(item.label, math.floor(math.max(0, available - hint_width - (hint ~= "" and 2 or 0))), "…")
            local gap = string.rep(" ", math.floor(math.max(0, available - tty.text.width(label) - hint_width)))
            local text = style .. " " .. label .. gap .. hint_style .. hint .. style .. " "
            canvas:put(panel.x + 1, y, text .. "\27[0m", inside)
        end
    end
end
return M

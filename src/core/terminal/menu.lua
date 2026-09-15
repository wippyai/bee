-- One bounded Start panel. Its layout is used unchanged by drawing and input.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local names = require("names")
local display_transfer = require("display_transfer")
type Descriptor = {definition_id: string, title: string, group: string, role: string}
type TransferItem = display_transfer.Item
type TransferSnapshot = display_transfer.Snapshot
type Item = {label: string, action: string, enabled: boolean, shortcut: string?, children: {Item}?}
type State = {selected: integer, offset: integer, kind: string?, target: string?, x: integer?, y: integer?, path: {integer}?}
type Panel = {x: integer, y: integer, width: integer, height: integer, capacity: integer, inset: integer}
type Response = {state: State, action: string, close: boolean}
local M = {}
function M.items(focused: boolean, initial: boolean, has_windows: boolean?, catalog: {Descriptor}?): {Item}
    local items: {Item} = {}
    for _, descriptor in ipairs(catalog or {}) do
        local current = items
        for part in descriptor.group:gmatch("[^/]+") do
            local found: Item? = nil
            for _, item in ipairs(current) do
                if item.children and item.action == "group:" .. part then found = item; break end
            end
            if not found then
                found = {label = part, action = "group:" .. part, enabled = true, children = {}}
                current[#current + 1] = found
            end
            if found.children then current = found.children end
        end
        current[#current + 1] = {label = descriptor.title, action = "open:" .. descriptor.definition_id, enabled = true}
    end
    if initial then table.insert(items, 1, {label = "Open application", shortcut = "Ctrl+N", action = "initial", enabled = true}) end
    items[#items + 1] = {label = "Exit", shortcut = "Ctrl+Q", action = "quit", enabled = true}
    return items
end
local function descend(items: {Item}, path: {integer}?): {Item}
    for _, index in ipairs(path or {}) do
        local item = items[index]
        if item and item.children then items = item.children else break end
    end
    return items
end
function M.entries(state: State, scene: model.Scene, initial: boolean, catalog: {Descriptor}?, transfers: TransferSnapshot?, display_id: string?): {Item}
    if state.kind == "window" then
        for _, win in ipairs(scene.windows) do
            if win.id == state.target then
                local transfer_items: {Item} = {}
                local transfer_item: TransferItem? = nil
                for _, item in ipairs(transfers and transfers.items or {}) do
                    if item.tab_id == win.id and item.instance_id == win.instance_id then transfer_item = item; break end
                end
                if transfer_item then
                    for _, target in ipairs(transfer_item.targets) do
                        if target ~= display_id then
                            transfer_items[#transfer_items + 1] = {label = names.label(target), action = "transfer:" .. target, enabled = true}
                        end
                    end
                end
                return descend({
                    {label = "Restore", action = "restore", enabled = win.mode ~= "floating"},
                    {label = "Minimize", shortcut = "Alt+F9", action = "minimize", enabled = win.mode ~= "minimized"},
                    {label = "Maximize / restore", shortcut = "F11", action = "fullscreen", enabled = win.mode ~= "minimized"},
                    {label = "Snap left", action = "snap_left", enabled = win.mode ~= "minimized"},
                    {label = "Snap right", action = "snap_right", enabled = win.mode ~= "minimized"},
                    {label = "Collapse", action = "collapse", enabled = win.mode == "floating"},
                    {label = "Rename…", action = "rename", enabled = true},
                    {label = "Select text", action = "select_text", enabled = win.mode ~= "collapsed"},
                    {label = "Send to display", action = "group:transfer", enabled = #transfer_items > 0, children = transfer_items},
                    {label = "Accent", action = "group:accent", enabled = true, children = {
                        {label = "Theme default", action = "accent:", enabled = true},
                        {label = "Amber", action = "accent:amber", enabled = true},
                        {label = "Cyan", action = "accent:cyan", enabled = true},
                        {label = "Green", action = "accent:green", enabled = true},
                        {label = "Rose", action = "accent:rose", enabled = true},
                        {label = "Violet", action = "accent:violet", enabled = true},
                    }},
                    {label = "Close", shortcut = "Ctrl+W", action = "close", enabled = true},
                }, state.path)
            end
        end
        return {}
    elseif state.kind == "desktop" then
        local items: {Item} = {}
        for _, descriptor in ipairs(catalog or {}) do
            if descriptor.role == "appearance" or descriptor.role == "inspection" then
                items[#items + 1] = {label = descriptor.title, action = "open:" .. descriptor.definition_id, enabled = true}
            end
        end
        items[#items + 1] = {label = "Restore windows", action = "restore_all", enabled = #scene.windows > 0}
        items[#items + 1] = {label = "Reload desktop", shortcut = "F12", action = "rejoin", enabled = true}
        return items
    end
    local items = M.items(scene.focus ~= "", initial, #scene.windows > 0, catalog)
    for _, index in ipairs(state.path or {}) do
        local item = items[index]
        if item and item.children then items = item.children else break end
    end
    return items
end
function M.panel(width: integer, height: integer, count: integer, state: State?): Panel
    local y = height >= 4 and 2 or 1
    local inset = state and state.path and #state.path > 0 and 1 or 0
    local h = math.floor(math.max(1, math.min(count + 2 + inset, height - y + 1)))
    local w = math.floor(math.min(35, width))
    local x = 1
    if state and state.kind then
        x = math.floor(math.max(1, math.min(state.x or 1, width - w + 1)))
        y = math.floor(math.max(1, math.min(state.y or y, height - h + 1)))
    end
    return {x = x, y = y, width = w, height = h, capacity = math.floor(math.max(0, h - 2 - inset)), inset = inset}
end
function M.fit(state: State, panel: Panel, count: integer): State
    local selected = math.floor(math.max(1, math.min(count, state.selected)))
    local offset = math.floor(math.max(0, math.min(state.offset, count - panel.capacity)))
    if selected <= offset then offset = selected - 1 end
    if selected > offset + panel.capacity then offset = math.floor(math.max(0, selected - panel.capacity)) end
    return {selected = selected, offset = offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}
end
function M.move(state: State, step: integer, items: {Item}, panel: Panel): State
    if #items == 0 then return state end
    local index = state.selected
    for _ = 1, #items do
        index = (index - 1 + step + #items) % #items + 1
        if items[index].enabled then break end
    end
    return M.fit({selected = index, offset = state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
end
function M.hit(panel: Panel, state: State, x: integer, y: integer, count: integer): integer?
    if x <= panel.x or x >= panel.x + panel.width - 1 or y < panel.y + 1 + panel.inset or y >= panel.y + panel.height - 1 then return nil end
    local index = state.offset + y - panel.y - panel.inset
    if index >= 1 and index <= count then return index end
    return nil
end
function M.respond(state: State, panel: Panel, items: {Item}, event: unknown): Response
    local next_state = M.fit(state, panel, #items)
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
                next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
                if items[index] and not items[index].enabled then next_state = M.move(next_state, direction, items, panel) end
            elseif event.key_type == "home" then next_state = M.fit({selected = 1, offset = 0, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
            elseif event.key_type == "end" then next_state = M.fit({selected = #items, offset = 0, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
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
            local index = M.hit(panel, next_state, x, y, #items)
            if event.action == "motion" and index and items[index].enabled then
                next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind,
                    target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
            elseif event.action == "wheel" then
                local up = event.button == "wheel_up" or event.button == "up"
                next_state = M.move(next_state, up and -1 or 1, items, panel)
            elseif event.action == "press" and event.button == "right" then
                close = true
            elseif event.action == "press" and event.button == "left" then
                if panel.inset > 0 and y == panel.y + 1 and x > panel.x and x < panel.x + panel.width - 1 then back()
                elseif index and items[index].enabled then
                    next_state = M.fit({selected = index, offset = next_state.offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = state.path}, panel, #items)
                    activate(index)
                elseif x < panel.x or x >= panel.x + panel.width or y < panel.y or y >= panel.y + panel.height then close = true end
            end
        end
    end
    return {state = next_state, action = action, close = close}
end
function M.draw(canvas: tty.Canvas, panel: Panel, state: State, items: {Item}, preferences: appearance.Preferences)
    local theme = appearance.theme(preferences.theme)
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
        canvas:put(panel.x + 1, panel.y + 1, normal .. " ‹ Back\27[0m", inside)
    end
    for row = 1, panel.capacity do
        local index = state.offset + row
        local item = items[index]
        if item then
            local style = item.enabled and normal or appearance.style(theme.muted, theme.surface)
            local hint_style = appearance.style(theme.muted, theme.surface)
            if index == state.selected and item.enabled then
                style = appearance.style(appearance.selection_text(theme), theme.accent)
                hint_style = style
            end
            local available = math.floor(math.max(0, inside - 2))
            local hint = item.children and "›" or (item.shortcut or "")
            if tty.text.width(hint) + 4 > available then hint = "" end
            local hint_width = tty.text.width(hint)
            local label = tty.text.truncate(item.label, math.floor(math.max(0, available - hint_width - (hint ~= "" and 2 or 0))), "…")
            local gap = string.rep(" ", math.floor(math.max(0, available - tty.text.width(label) - hint_width)))
            local text = normal .. " " .. style .. label .. gap .. hint_style .. hint .. normal .. " "
            canvas:put(panel.x + 1, panel.y + panel.inset + row, text .. "\27[0m", inside)
        end
    end
end
return M

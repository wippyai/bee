-- MIT. A popup menu anchored at a cell: the shell's Start, window and
-- desktop menus and the row menus applications declare through the frame.
-- A rule separates a group from the items above it; an item with children
-- opens a submenu. The layout is used unchanged by drawing and input.
local tty = require("tty")
local appearance = require("appearance")
local M = {}
local RESET = "\27[0m"
local ELLIPSIS = "…"

type Item = {label: string, action: string, enabled: boolean, shortcut: string?, children: {Item}?, group: boolean?}
type State = {selected: integer, offset: integer, kind: string?, target: string?, x: integer?, y: integer?, path: {integer}?}
type Panel = {x: integer, y: integer, width: integer, height: integer, capacity: integer, inset: integer}
type Response = {state: State, action: string, close: boolean}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end

-- lines lays items out as drawn rows: each item's index, with 0 for
-- the rule before an item that starts a group.
local function lines(items: {Item}): {integer}
    local laid: {integer} = {}
    for index, item in ipairs(items) do
        if item.group and index > 1 then laid[#laid + 1] = 0 end
        laid[#laid + 1] = index
    end
    return laid
end
local function line_of(laid: {integer}, index: integer): integer
    for line, item in ipairs(laid) do
        if item == index then return line end
    end
    return 1
end
local function state_of(state: State, selected: integer, offset: integer, path: {integer}?): State
    return {selected = selected, offset = offset, kind = state.kind, target = state.target, x = state.x, y = state.y, path = path}
end

-- The panel for items at the state's anchor cell (x, y), kept on the
-- canvas at or below row top (default 1). size is the panel's width; by
-- default it fits the widest item.
function M.panel(width: integer, height: integer, items: {Item}, state: State, size: integer?, top: integer?): Panel
    local first = maximum(1, minimum(top or 1, height))
    local inset = state.path and #state.path > 0 and 1 or 0
    local fitted = 0
    for _, item in ipairs(items) do
        local hint = item.children and "›" or (item.shortcut or "")
        fitted = maximum(fitted, tty.text.width(item.label) + (hint ~= "" and tty.text.width(hint) + 2 or 0) + 4)
    end
    local w = minimum(size or maximum(fitted, 12), width)
    local h = maximum(1, minimum(#lines(items) + 2 + inset, height - first + 1))
    local x = maximum(1, minimum(state.x or 1, width - w + 1))
    local y = maximum(first, minimum(state.y or first, height - h + 1))
    return {x = x, y = y, width = w, height = h, capacity = maximum(0, h - 2 - inset), inset = inset}
end

-- fit clamps the selection to items and scrolls the drawn rows
-- (offset) to keep it in view.
function M.fit(state: State, panel: Panel, items: {Item}): State
    local laid = lines(items)
    local selected = maximum(1, minimum(#items, state.selected))
    local offset = maximum(0, minimum(state.offset, #laid - panel.capacity))
    local line = line_of(laid, selected)
    if line <= offset then offset = line - 1 end
    if line > offset + panel.capacity then offset = maximum(0, line - panel.capacity) end
    return state_of(state, selected, offset, state.path)
end

-- move steps the selection to the next enabled item, wrapping.
function M.move(state: State, step: integer, items: {Item}, panel: Panel): State
    if #items == 0 then return state end
    local index = state.selected
    for _ = 1, #items do
        index = (index - 1 + step + #items) % #items + 1
        if items[index].enabled then break end
    end
    return M.fit(state_of(state, index, state.offset, state.path), panel, items)
end

-- The item drawn at the cell (x, y), if any.
function M.hit(panel: Panel, state: State, x: integer, y: integer, items: {Item}): integer?
    if x <= panel.x or x >= panel.x + panel.width - 1 or y < panel.y + 1 + panel.inset or y >= panel.y + panel.height - 1 then return nil end
    local index = lines(items)[state.offset + y - panel.y - panel.inset]
    if index and index >= 1 then return index end
    return nil
end

-- respond answers one input event: navigation keys, the pointer,
-- Enter on an item (its action), a submenu's Back, and Esc or a click outside
-- the panel (close).
function M.respond(state: State, panel: Panel, items: {Item}, event: unknown): Response
    local next_state = M.fit(state, panel, items)
    local action, close = "", false
    local function back()
        local path: {integer} = {}
        for _, index in ipairs(next_state.path or {}) do path[#path + 1] = index end
        if #path == 0 then close = true; return end
        local selected = table.remove(path)
        next_state = state_of(state, selected or 1, 0, path)
    end
    local function activate(index: integer)
        local item = items[index]
        if not item or not item.enabled then return end
        if item.children then
            local path: {integer} = {}
            for _, parent in ipairs(next_state.path or {}) do path[#path + 1] = parent end
            path[#path + 1] = index
            next_state = state_of(state, 1, 0, path)
        else action = item.action end
    end
    if type(event) ~= "table" then return {state = next_state, action = action, close = close} end
    if event.type == "key" and event.action ~= "release" then
        local key = event.key_type
        if key == "up" then next_state = M.move(next_state, -1, items, panel)
        elseif key == "down" or key == "tab" then next_state = M.move(next_state, 1, items, panel)
        elseif key == "pgup" or key == "pgdown" then
            local direction = key == "pgup" and -1 or 1
            local index = maximum(1, minimum(#items, next_state.selected + direction * maximum(1, panel.capacity)))
            next_state = M.fit(state_of(state, index, next_state.offset, state.path), panel, items)
            if items[index] and not items[index].enabled then next_state = M.move(next_state, direction, items, panel) end
        elseif key == "home" then next_state = M.fit(state_of(state, 1, 0, state.path), panel, items)
        elseif key == "end" then next_state = M.fit(state_of(state, #items, 0, state.path), panel, items)
        elseif key == "enter" then activate(next_state.selected)
        elseif key == "right" then
            local item = items[next_state.selected]
            if item and item.children then activate(next_state.selected) end
        elseif key == "left" or key == "backspace" or key == "esc" or key == "escape" then back() end
    elseif event.type == "mouse" and type(event.x) == "number" and type(event.y) == "number" then
        local x, y = math.floor(event.x), math.floor(event.y)
        local index = M.hit(panel, next_state, x, y, items)
        if event.action == "motion" and index and items[index].enabled then
            next_state = M.fit(state_of(state, index, next_state.offset, state.path), panel, items)
        elseif event.action == "wheel" then
            local up = event.button == "wheel_up" or event.button == "up"
            next_state = M.move(next_state, up and -1 or 1, items, panel)
        elseif event.action == "press" and event.button == "right" then
            close = true
        elseif event.action == "press" and event.button == "left" then
            if panel.inset > 0 and y == panel.y + 1 and x > panel.x and x < panel.x + panel.width - 1 then back()
            elseif index and items[index].enabled then
                next_state = M.fit(state_of(state, index, next_state.offset, state.path), panel, items)
                activate(index)
            elseif x < panel.x or x >= panel.x + panel.width or y < panel.y or y >= panel.y + panel.height then close = true end
        end
    end
    return {state = next_state, action = action, close = close}
end

-- Draws the panel: a rounded border, a submenu's Back row, rules between
-- groups, and each item's label with its shortcut, or "›" for a submenu,
-- aligned right. The selected enabled item takes the selection pair and
-- disabled items are muted.
function M.draw(canvas: tty.Canvas, panel: Panel, state: State, items: {Item}, theme: appearance.Theme)
    local normal = appearance.style(theme.text, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local inside = maximum(0, panel.width - 2)
    for y = panel.y, panel.y + panel.height - 1 do
        local edge = y == panel.y or y == panel.y + panel.height - 1
        local row = "│" .. string.rep(" ", inside) .. "│"
        if edge then row = (y == panel.y and "╭" or "╰") .. string.rep("─", inside) .. (y == panel.y and "╮" or "╯") end
        canvas:put(panel.x, y, border .. row .. RESET, panel.width)
    end
    if panel.height < 3 or panel.width < 4 then return end
    if panel.inset > 0 then
        canvas:put(panel.x + 1, panel.y + 1, appearance.style(theme.muted, theme.surface) .. " ‹ Back" .. RESET, inside)
    end
    local laid = lines(items)
    local muted = appearance.style(theme.muted, theme.surface)
    for row = 1, panel.capacity do
        local index = laid[state.offset + row]
        local item = index and items[index]
        local y = panel.y + panel.inset + row
        if index == 0 then
            canvas:put(panel.x, y, border .. "├" .. string.rep("─", inside) .. "┤" .. RESET, panel.width)
        elseif index and item then
            local style = item.enabled and normal or muted
            local hint_style = muted
            if index == state.selected and item.enabled then
                style = appearance.style(appearance.selection_text(theme), appearance.selection_background(theme))
                hint_style = style
            end
            local available = maximum(0, inside - 2)
            local hint = item.children and "›" or (item.shortcut or "")
            if tty.text.width(hint) + 4 > available then hint = "" end
            local hint_width = tty.text.width(hint)
            local label = tty.text.truncate(item.label, maximum(0, available - hint_width - (hint ~= "" and 2 or 0)), ELLIPSIS)
            local gap = string.rep(" ", maximum(0, available - tty.text.width(label) - hint_width))
            canvas:put(panel.x + 1, y, style .. " " .. label .. gap .. hint_style .. hint .. style .. " " .. RESET, inside)
        end
    end
end

return M

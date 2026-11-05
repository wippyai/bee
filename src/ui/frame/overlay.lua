-- MIT. The shared overlay of an application frame: the More and Help screens
-- and a row's action menu, drawn over a painted view from the controls the
-- screen declared, and the input routing that answers them before the app
-- sees an event. The app retains one menu state between redraws.
local tty = require("tty")
local appearance = require("appearance")
local popup = require("popup")
local paint = require("paint")
local M = {}

type Hit = paint.Hit
type Button = paint.Button
type RowActions = paint.RowActions
type Controls = paint.Controls
type View = paint.View
type MenuItem = popup.Item
type PopupState = popup.State
type Panel = popup.Panel
-- context is the row whose actions are open; state anchors the popup and
-- panel is where it was last drawn.
type Context = {kind: string, key: string, index: integer, state: PopupState, panel: Panel?}
type Menu = {mode: string, selected: integer, offset: integer, controls: Controls, hits: {Hit}, signature: string, count: integer, context: Context?}

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end

-- An app-owned More and Help state; the app retains it between redraws.
function M.menu(): Menu
    local controls: Controls = {buttons = {}, overflow = {}, hints = {}, status = "", rows = {}}
    return {mode = "", selected = 1, offset = 0, controls = controls, hits = {}, signature = "", count = 0}
end

local function choices(menu: Menu): {Button}
    if menu.mode == "more" then return menu.controls.overflow end
    if menu.mode == "context" then
        local context = menu.context
        for _, row in ipairs(menu.controls.rows) do
            if context and row.kind == context.kind and row.key == context.key and (row.key ~= "" or row.index == context.index) then
                context.index = row.index
                return row.actions
            end
        end
        return {}
    end
    return menu.controls.buttons
end

local function context_items(buttons: {Button}): {MenuItem}
    local items: {MenuItem} = {}
    for _, button in ipairs(buttons) do
        items[#items + 1] = {label = button.label, action = button.kind, enabled = button.enabled, shortcut = button.key}
    end
    return items
end

-- The row's actions drawn over the screen at the context's anchor; false
-- when the row offers none.
local function render_context(view: View, menu: Menu, preferences: appearance.Preferences): boolean
    local context = menu.context
    local buttons = choices(menu)
    if not context or #buttons == 0 then return false end
    local painter = paint.new(tty.text.width(view.rows[1] or ""), #view.rows, preferences)
    painter.canvas:put_rows(1, 1, view.rows)
    local items = context_items(buttons)
    local panel = popup.panel(painter.width, painter.height, items, context.state)
    context.state, context.panel = popup.fit(context.state, panel, items), panel
    popup.draw(painter.canvas, panel, context.state, items, painter.theme)
    view.rows, view.hits = paint.rows(painter), painter.hits
    menu.hits = view.hits
    return true
end

-- Paints a shared overlay from this screen's declared buttons and hints.
function M.render(view: View, menu: Menu, preferences: appearance.Preferences)
    local controls: Controls
    if view.controls then controls = view.controls
    else controls = {buttons = {}, overflow = {}, hints = {}, status = "", rows = {}} end
    local parts: {string} = {}
    for _, button in ipairs(controls.buttons) do parts[#parts + 1] = button.kind end
    for _, hint in ipairs(controls.hints) do parts[#parts + 1] = hint.key .. hint.verb end
    local signature = table.concat(parts, "\n")
    if signature ~= menu.signature then menu.mode, menu.selected, menu.offset = "", 1, 0 end
    menu.signature, menu.controls = signature, controls
    if menu.mode == "more" and #controls.overflow == 0 then menu.mode = "" end
    if menu.mode == "context" and not render_context(view, menu, preferences) then menu.mode, menu.context = "", nil end
    if menu.mode == "context" then return end
    if menu.mode == "" then menu.hits = view.hits; return end
    local painter = paint.new(tty.text.width(view.rows[1] or ""), #view.rows, preferences)
    paint.header(painter, menu.mode == "more" and "MORE ACTIONS" or "HELP", "Esc back")
    paint.add_hit(painter, "frame_back", 0, "", maximum(1, painter.width - 8), 1, 8, 1)
    local items = choices(menu)
    local lines: {string} = {}
    local muted: {[integer]: boolean} = {}
    local function add(line: string, unavailable: boolean?)
        lines[#lines + 1] = line .. (unavailable and " · unavailable" or "")
        muted[#lines] = unavailable == true
    end
    if menu.mode ~= "help" then
        for _, button in ipairs(items) do add((button.key and (button.key .. "  ") or "") .. button.label, not button.enabled) end
    else
        -- Help names each key once: a button's label wins over a hint for
        -- the same key, tabs share one line and keyless buttons are clicked.
        local tabs: {string} = {}
        for _, button in ipairs(items) do if button.tab then tabs[#tabs + 1] = button.label end end
        if #tabs > 0 then add("Tabs  " .. table.concat(tabs, " · ")) end
        local named: {[string]: boolean} = {}
        for _, button in ipairs(items) do
            if not button.tab then
                if button.key then named[button.key:lower()] = true end
                add((button.key or "Click") .. "  " .. button.label, not button.enabled)
            end
        end
        for _, hint in ipairs(controls.hints) do
            if not named[hint.key:lower()] then add(hint.key .. "  " .. hint.verb); named[hint.key:lower()] = true end
        end
        if #controls.overflow > 0 and not named["f10"] then add("F10  More actions") end
        local status = controls.status or ""
        if status ~= "" then
            local remaining = "Status: " .. status
            while remaining ~= "" and painter.width > 2 do
                local shown = tty.text.truncate(remaining, painter.width - 2, "")
                if shown == "" then break end
                lines[#lines + 1] = shown
                remaining = remaining:sub(#shown + 1)
            end
        end
    end
    menu.count = #lines
    menu.selected = minimum(maximum(1, menu.selected), maximum(1, #lines))
    local window = paint.window(#lines, painter.height - 4, menu.selected, menu.offset)
    menu.offset = window.offset
    for slot = 1, window.capacity do
        local index = window.offset + slot
        if not lines[index] then break end
        paint.row(painter, slot + 2, lines[index], index == menu.selected, "frame_choice", index, "", muted[index] and painter.theme.muted or nil)
    end
    paint.footer(painter, "", menu.mode == "more" and "↑↓ select · Enter choose" or "↑↓ scroll")
    view.rows, view.hits = paint.rows(painter), painter.hits
    menu.hits = view.hits
end

-- dispatch closes the overlay and hands the chosen button to the app as a
-- press on a target of the button's kind, placed first so the app's hit
-- test finds it, carrying the row's index and key for a row action.
local function dispatch(menu: Menu, button: Button, index: integer, key: string): tty.TTYEvent
    table.insert(menu.hits, 1, {kind = button.kind, index = index, key = key, x = 1, y = 1, width = 1, height = 1})
    menu.mode, menu.context = "", nil
    return {type = "mouse", action = "press", button = "left", x = 1, y = 1, ctrl = false, alt = false, shift = false}
end

local function choose(menu: Menu, index: integer): tty.TTYEvent?
    local button = choices(menu)[index]
    if (menu.mode ~= "more" and menu.mode ~= "context") or not button or not button.enabled then return nil end
    local context = menu.context
    if menu.mode == "context" and context then return dispatch(menu, button, context.index, context.key) end
    return dispatch(menu, button, 0, "")
end

-- open_context opens the actions of the row at target, anchored at (x, y).
local function open_context(menu: Menu, row: RowActions, x: integer, y: integer)
    menu.mode = "context"
    local first = 1
    for index, button in ipairs(row.actions) do
        if button.enabled then first = index; break end
    end
    menu.context = {kind = row.kind, key = row.key, index = row.index, state = {selected = first, offset = 0, x = x, y = y}}
end

local function row_at(menu: Menu, hit: Hit): RowActions?
    for _, row in ipairs(menu.controls.rows) do
        if row.kind == hit.kind and row.index == hit.index and row.key == hit.key then return row end
    end
    return nil
end

-- context_input answers one event while a row's actions are open.
local function context_input(menu: Menu, event: tty.TTYEvent): tty.TTYEvent?
    local context = menu.context
    local buttons = choices(menu)
    if not context then menu.mode = ""; return nil end
    if event.type == "key" and not event.ctrl and not event.alt and event.key_type ~= "enter" then
        for index, button in ipairs(buttons) do
            if button.key and #button.key == 1 and button.key:lower() == (event.key or ""):lower() then return choose(menu, index) end
        end
    end
    local panel = context.panel
    if not panel then return nil end
    local response = popup.respond(context.state, panel, context_items(buttons), event)
    context.state = response.state
    if response.close then menu.mode, menu.context = "", nil end
    if response.action ~= "" then return choose(menu, context.state.selected) end
    return nil
end

local function coordinate(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value < 1 or value > 2147483647 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function input_event(value: unknown): tty.TTYEvent?
    if type(value) ~= "table" then return nil end
    if value.ctrl ~= nil and type(value.ctrl) ~= "boolean" then return nil end
    if value.alt ~= nil and type(value.alt) ~= "boolean" then return nil end
    if value.shift ~= nil and type(value.shift) ~= "boolean" then return nil end
    if value.type == "key" then
        if (value.key ~= nil and type(value.key) ~= "string") or type(value.key_type) ~= "string" or (value.action ~= "press" and value.action ~= "release") then return nil end
        return {type = "key", key = type(value.key) == "string" and value.key or "", key_type = value.key_type, action = value.action == "release" and "release" or "press", ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "mouse" then
        local x, y = coordinate(value.x), coordinate(value.y)
        if not x or not y or type(value.button) ~= "string" or (value.action ~= "press" and value.action ~= "release" and value.action ~= "motion" and value.action ~= "wheel") then return nil end
        return {type = "mouse", x = x, y = y, button = value.button, action = value.action == "release" and "release" or (value.action == "motion" and "motion" or (value.action == "wheel" and "wheel" or "press")), ctrl = value.ctrl == true, alt = value.alt == true, shift = value.shift == true}
    elseif value.type == "start" or value.type == "resize" then
        local width, height = coordinate(value.width), coordinate(value.height)
        if not width or not height then return nil end
        if value.type == "start" then return {type = "start", width = width, height = height} end
        return {type = "resize", width = width, height = height}
    elseif value.type == "paste" and type(value.text) == "string" then return {type = "paste", text = value.text}
    elseif value.type == "focus" and type(value.focused) == "boolean" then return {type = "focus", focused = value.focused}
    elseif value.type == "visibility" and type(value.visible) == "boolean" then return {type = "visibility", visible = value.visible}
    elseif value.type == "close" then return {type = "close"} end
    return nil
end

-- Returns nil for consumed input. Selected actions reuse the app's mouse path.
-- text_entry preserves letters and '?' while a form or editor owns input.
function M.route(menu: Menu, value: unknown, text_entry: boolean?): (tty.TTYEvent?, boolean)
    local event = input_event(value)
    if not event then return nil, false end
    if event.type == "start" or event.type == "resize" or event.type == "close" then return event, false end
    if menu.mode == "context" then
        if event.type == "key" and event.action == "release" then return nil, true end
        return context_input(menu, event), true
    end
    -- Shift+F10 opens the selected row's actions under the row.
    if menu.mode == "" and event.type == "key" and event.action ~= "release" and not event.ctrl and not event.alt
        and event.key_type == "f10" and event.shift then
        for _, row in ipairs(menu.controls.rows) do
            if row.selected then
                for _, hit in ipairs(menu.hits) do
                    if row_at(menu, hit) == row then open_context(menu, row, hit.x + 2, hit.y + 1); return nil, true end
                end
            end
        end
    end
    if menu.mode == "" and event.type == "mouse" and event.action == "press" and event.button == "right" then
        local hit = paint.hit(menu.hits, event.x or 0, event.y or 0)
        local row = hit and row_at(menu, hit)
        if row then
            open_context(menu, row, event.x or 1, (event.y or 1) + 1)
            table.insert(menu.hits, 1, {kind = row.select or row.kind, index = row.index, key = row.key, x = 1, y = 1, width = 1, height = 1})
            return {type = "mouse", action = "press", button = "left", x = 1, y = 1, ctrl = false, alt = false, shift = false}, true
        end
    end
    if event.type == "key" and event.action ~= "release" then
        local key, letter = event.key_type or "", event.key or ""
        local plain = not event.ctrl and not event.alt
        if plain and (key == "f10" or (letter == "?" and not text_entry)) then
            local mode = key == "f10" and "more" or "help"
            if mode ~= "more" or #menu.controls.overflow > 0 then
                menu.mode = menu.mode == mode and "" or mode
                menu.selected, menu.offset = 1, 0
                return nil, true
            end
        end
        if menu.mode ~= "" then
            if key == "esc" or key == "escape" then menu.mode = ""
            elseif key == "up" then menu.selected = maximum(1, menu.selected - 1)
            elseif key == "down" then menu.selected = menu.selected + 1
            elseif key == "tab" then menu.selected = menu.selected + (event.shift and -1 or 1)
            elseif key == "pgup" then menu.selected = maximum(1, menu.selected - 8)
            elseif key == "pgdown" then menu.selected = menu.selected + 8
            elseif key == "home" then menu.selected = 1
            elseif key == "end" then menu.selected = menu.count
            elseif key == "enter" then return choose(menu, menu.selected), true
            elseif plain and menu.mode == "more" then
                for index, button in ipairs(choices(menu)) do
                    if button.key and button.key:lower() == letter:lower() then return choose(menu, index), true end
                end
            end
            return nil, true
        end
    elseif event.type == "mouse" then
        local hit = paint.hit(menu.hits, event.x or 0, event.y or 0)
        if event.action == "press" and event.button == "left" and hit then
            if hit.kind == "frame_back" then
                menu.mode = ""
                return nil, true
            elseif hit.kind == "frame_more" or hit.kind == "frame_help" then
                menu.mode = hit.kind == "frame_more" and "more" or "help"
                menu.selected, menu.offset = 1, 0
                return nil, true
            elseif hit.kind == "frame_choice" and menu.mode == "more" then return choose(menu, hit.index), true end
        end
        if menu.mode ~= "" then
            if event.action == "wheel" then menu.selected = maximum(1, menu.selected + ((event.button == "wheel_up" or event.button == "up") and -1 or 1)) end
            return nil, true
        end
    end
    if menu.mode ~= "" then return nil, false end
    if event.type == "key" and event.key and event.action ~= "release" and (not text_entry or event.ctrl) and not event.alt then
        return {type = "key", action = event.action, key = event.key:lower(), key_type = event.key_type,
            ctrl = event.ctrl, alt = event.alt, shift = event.shift}, false
    end
    return event, false
end

-- A double click is a second press on the same target within
-- DOUBLE_CLICK_MS of the first; the press that completes one starts over.
M.DOUBLE_CLICK_MS = 400
type Clicks = {kind: string, index: integer, at_ms: integer}
function M.clicks(): Clicks
    return {kind = "", index = 0, at_ms = 0}
end
function M.double_click(memory: Clicks, kind: string, index: integer, now_ms: integer): boolean
    local double = memory.kind == kind and memory.index == index and now_ms - memory.at_ms <= M.DOUBLE_CLICK_MS
    if double then memory.kind, memory.index, memory.at_ms = "", 0, 0
    else memory.kind, memory.index, memory.at_ms = kind, index, now_ms end
    return double
end

return M

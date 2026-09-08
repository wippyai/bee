-- MIT. A pure, bounded interaction modal for the replaceable presenter.
local tty = require("tty")
local appearance = require("appearance")

type Kind = "confirm" | "text"
type Action = "" | "accept" | "cancel"
type Spec = {request_id: string, id: string, instance_id: string, kind: Kind,
    title: string, message: string, accept: string, initial: string}
type State = {spec: Spec, left: string, right: string, selected: boolean, focus: string}
type Result = {state: State, action: Action, value: string}
type Cursor = {x: integer, y: integer, visible: boolean}
type Panel = {x: integer, y: integer, width: integer, height: integer}
type Button = {x: integer, width: integer, action: Action}

local M = {}
local MAX_BYTES = 256

local function copy_spec(spec: Spec): Spec
    return {request_id = spec.request_id, id = spec.id, instance_id = spec.instance_id,
        kind = spec.kind, title = spec.title, message = spec.message,
        accept = spec.accept, initial = spec.initial}
end

-- The interaction decoder already rejects controls and oversized initial values.
-- Keep the renderer defensive because it is also useful with directly-created
-- values in pure tests and callers that have not crossed that decoder.
local function utf8_size(first: integer): integer
    if first < 0x80 then return 1 end
    if first < 0xe0 then return 2 end
    if first < 0xf0 then return 3 end
    if first < 0xf8 then return 4 end
    return 1
end

local function bounded_initial(text: string): string
    local result: {string} = {}
    local bytes = 0
    local index = 1
    while index <= #text and bytes < MAX_BYTES do
        local first = text:byte(index) or 0
        if first < 0x20 or first == 0x7f then
            index = index + 1
        else
            local size = math.floor(math.min(utf8_size(first), #text - index + 1))
            if bytes + size > MAX_BYTES then break end
            result[#result + 1] = text:sub(index, index + size - 1)
            bytes = bytes + size
            index = index + size
        end
    end
    return table.concat(result)
end

local function value(state: State): string
    return state.left .. state.right
end

local function pop(text: string): (string, string)
    if text == "" then return "", "" end
    local prefix = tty.text.truncate(text, math.floor(math.max(0, tty.text.width(text) - 1)), "")
    if prefix == "" then return "", text end
    return prefix, text:sub(#prefix + 1)
end

local function shift(text: string): (string, string)
    if text == "" then return "", "" end
    for width = 1, tty.text.width(text) do
        local first = tty.text.truncate(text, width, "")
        if first ~= "" then return first, text:sub(#first + 1) end
    end
    return text, ""
end

local function clone(state: State): State
    return {spec = state.spec, left = state.left, right = state.right,
        selected = state.selected, focus = state.focus}
end

local function focus_order(state: State): {string}
    if state.spec.kind == "confirm" then return {"accept", "cancel"} end
    return {"text", "accept", "cancel"}
end

local function next_focus(state: State, backwards: boolean): string
    local order = focus_order(state)
    for index, item in ipairs(order) do
        if item == state.focus then
            local step = backwards and -1 or 1
            return order[(index - 1 + step + #order) % #order + 1]
        end
    end
    return order[1]
end

local function insert(state: State, text: string)
    if text == "" or text:find("%c") then return end
    local left = state.selected and "" or state.left
    local right = state.selected and "" or state.right
    if #left + #right + #text > MAX_BYTES then return end
    state.left, state.right, state.selected = left .. text, right, false
end

local function message_lines(text: string, width: integer): {string}
    local lines: {string} = {}
    if width <= 0 then return lines end
    if text == "" then return {""} end
    local rest = text
    while rest ~= "" do
        local line = tty.text.truncate(rest, width, "")
        if line == "" then
            local first, remaining = shift(rest)
            line = tty.text.truncate(first, width, "")
            if line == "" then line = "…" end
            rest = remaining
        else
            rest = rest:sub(#line + 1)
        end
        lines[#lines + 1] = line
    end
    return lines
end

local function desired_width(state: State): integer
    local title = tty.text.width(state.spec.title)
    local message = tty.text.width(state.spec.message)
    local accept = tty.text.width("[" .. state.spec.accept .. "]")
    local cancel = tty.text.width("[Cancel]")
    return math.floor(math.min(64, math.max(18, title, message, accept + cancel + 1) + 4))
end

local function panel(state: State, width: integer, height: integer): Panel
    local panel_width = math.floor(math.max(1, math.min(width, desired_width(state))))
    local message_width = math.floor(math.max(1, panel_width - 4))
    local lines = message_lines(state.spec.message, message_width)
    local wanted = 4 + #lines + (state.spec.kind == "text" and 1 or 0)
    local panel_height = math.floor(math.max(1, math.min(height, math.min(16, wanted))))
    return {x = math.floor((width - panel_width) / 2) + 1,
        y = math.floor((height - panel_height) / 2) + 1,
        width = panel_width, height = panel_height}
end

local function button_layout(state: State, p: Panel): {Button}
    local inner = math.floor(math.max(0, p.width - 2))
    if inner == 0 or p.height == 0 then return {} end
    local left = p.x + 1
    local cancel_text = "[Cancel]"
    local cancel_width = math.floor(math.min(inner, math.max(1, tty.text.width(cancel_text))))
    local cancel_x = left + inner - cancel_width
    local gap = inner - cancel_width >= 2 and 1 or 0
    local accept_width = math.floor(math.max(0, cancel_x - left - gap))
    local result: {Button} = {}
    if accept_width > 0 then result[#result + 1] = {x = left, width = accept_width, action = "accept"} end
    result[#result + 1] = {x = cancel_x, width = cancel_width, action = "cancel"}
    return result
end

local function button_y(p: Panel): integer
    if p.height >= 3 then return p.y + p.height - 2 end
    return p.y + p.height - 1
end

local function input_y(state: State, p: Panel): integer?
    if state.spec.kind ~= "text" or p.height < 5 then return nil end
    local y = button_y(p) - 1
    if y <= p.y then return nil end
    return y
end

local function button_text(state: State, action: string, width: integer): string
    if width <= 0 then return "" end
    local text = action == "cancel" and "[Cancel]" or "[" .. state.spec.accept .. "]"
    if action == "cancel" and width == 1 then return "C" end
    return tty.text.truncate(text, width, "")
end

local function put(canvas: tty.Canvas, x: integer, y: integer, text: string,
    width: integer, foreground: string, background: string)
    if width <= 0 then return end
    canvas:put(x, y, appearance.style(foreground, background) .. text .. "\27[0m", width)
end

function M.open(spec: Spec): State
    local initial = spec.kind == "text" and bounded_initial(spec.initial) or ""
    return {spec = copy_spec(spec), left = initial, right = "", selected = false,
        focus = spec.kind == "confirm" and "cancel" or "text"}
end

function M.respond(value_state: State, event: unknown, width: integer, height: integer): Result
    local state = clone(value_state)
    local action: Action, answer = "", ""
    if type(event) == "table" then
        local event_type = event.type
        if event_type == "key" and event.action ~= "release" then
            local key = event.key_type
            if key == "esc" or key == "escape" then
                action = "cancel"
            elseif key == "tab" then
                state.focus = next_focus(state, event.shift == true)
            elseif key == "enter" then
                if state.focus == "cancel" then action = "cancel" else action = "accept" end
            elseif state.focus ~= "text" then
                if key == "space" then
                    action = state.focus == "cancel" and "cancel" or "accept"
                elseif key == "left" or key == "right" then
                    state.focus = state.focus == "accept" and "cancel" or "accept"
                end
            elseif event.ctrl == true and event.key == "a" then
                state.selected = true
            elseif key == "home" then
                state.right = state.left .. state.right; state.left = ""; state.selected = false
            elseif key == "end" then
                state.left = state.left .. state.right; state.right = ""; state.selected = false
            elseif key == "left" then
                if state.selected then state.right = state.left .. state.right; state.left = ""
                else local prefix, last = pop(state.left); state.left = prefix; state.right = last .. state.right end
                state.selected = false
            elseif key == "right" then
                if state.selected then state.left = state.left .. state.right; state.right = ""
                else local first, rest = shift(state.right); state.left = state.left .. first; state.right = rest end
                state.selected = false
            elseif key == "backspace" or key == "delete" then
                if state.selected then state.left, state.right = "", ""
                elseif key == "backspace" then local prefix = pop(state.left); state.left = prefix
                else local _, rest = shift(state.right); state.right = rest end
                state.selected = false
            elseif key == "space" and event.ctrl ~= true and event.alt ~= true then
                insert(state, " ")
            elseif key == "runes" and event.ctrl ~= true and event.alt ~= true
                and type(event.key) == "string" then
                insert(state, event.key)
            end
        elseif event_type == "paste" and state.focus == "text" and type(event.text) == "string" then
            insert(state, event.text)
        elseif event_type == "mouse" and event.action == "press" and event.button == "left"
            and type(event.x) == "number" and type(event.y) == "number" then
            local p = panel(state, math.floor(math.max(1, width)), math.floor(math.max(1, height)))
            local x, y = math.floor(event.x), math.floor(event.y)
            if y == button_y(p) then
                for _, button in ipairs(button_layout(state, p)) do
                    if x >= button.x and x < button.x + button.width then
                        action = button.action
                        break
                    end
                end
            elseif input_y(state, p) and y == input_y(state, p) and x >= p.x + 1 and x < p.x + p.width - 1 then
                state.focus = "text"
            end
        end
    end
    if action == "accept" and state.spec.kind == "text" then answer = value(state) end
    return {state = state, action = action, value = answer}
end

function M.draw(canvas: tty.Canvas, state: State, width: integer, height: integer,
    preferences: appearance.Preferences): Cursor
    local p = panel(state, math.floor(math.max(1, width)), math.floor(math.max(1, height)))
    local theme = appearance.theme(preferences.theme)
    local normal = appearance.style(theme.text, theme.surface)
    local border = appearance.style(theme.border, theme.surface)
    local muted = appearance.style(theme.muted, theme.surface)
    local active = appearance.style(appearance.selection_text(theme), theme.accent)
    local reset = "\27[0m"
    if p.width <= 0 or p.height <= 0 then return {x = 1, y = 1, visible = false} end

    for y = p.y, p.y + p.height - 1 do
        canvas:put(p.x, y, normal .. string.rep(" ", p.width) .. reset, p.width)
    end
    if p.width >= 2 and p.height >= 2 then
        canvas:put(p.x, p.y, border .. "╭" .. string.rep("─", p.width - 2) .. "╮" .. reset, p.width)
        canvas:put(p.x, p.y + p.height - 1, border .. "╰" .. string.rep("─", p.width - 2) .. "╯" .. reset, p.width)
        for y = p.y + 1, p.y + p.height - 2 do
            canvas:put(p.x, y, border .. "│" .. reset, 1)
            canvas:put(p.x + p.width - 1, y, border .. "│" .. reset, 1)
        end
    end

    local inner = math.floor(math.max(0, p.width - 2))
    local left = p.x + 1
    local buttons = button_layout(state, p)
    local buttons_row = button_y(p)
    if inner > 0 and p.height >= 3 then
        for _, button in ipairs(buttons) do
            local foreground, background = theme.text, theme.surface
            if state.focus == button.action then foreground, background = appearance.selection_text(theme), theme.accent end
            put(canvas, button.x, buttons_row, button_text(state, button.action, button.width), button.width, foreground, background)
        end
    elseif inner > 0 and #buttons > 0 then
        local button = buttons[#buttons]
        put(canvas, button.x, buttons_row, button_text(state, button.action, button.width), button.width, theme.text, theme.surface)
    end

    -- On a one-row viewport the only useful visible affordance is Cancel;
    -- keep the button from being overwritten by the clipped title/message.
    local top = p.height >= 3 and p.y + 1 or p.y
    local content_end = p.height >= 3 and buttons_row - 1 or (p.height == 2 and p.y or p.y - 1)
    local title_y = top
    if title_y <= content_end and inner > 0 then
        put(canvas, left, title_y, state.spec.title, inner, theme.accent, theme.surface)
    end

    local field_y = input_y(state, p)
    local message_end = content_end
    if field_y then message_end = field_y - 1 end
    local lines = message_lines(state.spec.message, math.floor(math.max(1, inner)))
    local line_y = title_y + 1
    for _, line in ipairs(lines) do
        if line_y > message_end then break end
        if inner > 0 then put(canvas, left, line_y, line, inner, theme.muted, theme.surface) end
        line_y = line_y + 1
    end

    local cursor: Cursor = {x = 1, y = 1, visible = false}
    if field_y and inner > 0 then
        local text = value(state)
        local room = math.floor(math.max(1, inner))
        local cursor_width = tty.text.width(state.left)
        local offset = math.floor(math.max(0, cursor_width - room + 1))
        local visible = tty.text.cut(text, offset, offset + room)
        local cursor_text = tty.text.cut(text, offset, cursor_width)
        local foreground = state.focus == "text" and appearance.selection_text(theme) or theme.text
        local background = state.focus == "text" and theme.accent or theme.surface
        put(canvas, left, field_y, visible, room, foreground, background)
        local cursor_x = left + tty.text.width(cursor_text)
        if state.focus == "text" and not state.selected then
            cursor = {x = math.floor(math.min(p.x + p.width - 2, math.max(p.x + 1, cursor_x))), y = field_y, visible = true}
        end
    end
    return cursor
end

return M

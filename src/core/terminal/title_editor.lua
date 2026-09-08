-- MIT. A bounded modal line editor; committed window values live in the session.
local tty = require("tty")
local appearance = require("appearance")
type State = {id: string, left: string, right: string, selected: boolean, focus: string, accent: string, error: string}
type Result = {state: State, action: string}
type Panel = {x: integer, y: integer, width: integer, height: integer}
local M = {}
function M.open(id: string, title: string, accent: string): State
    return {id = id, left = title, right = "", selected = true, focus = "text", accent = accent, error = ""}
end
function M.panel(width: integer, height: integer): Panel
    local w, h = math.floor(math.min(50, width)), math.floor(math.min(8, height))
    return {x = math.floor((width - w) / 2) + 1, y = math.floor((height - h) / 2) + 1, width = w, height = h}
end
local function pop(text: string): (string, string)
    local prefix = tty.text.truncate(text, math.floor(math.max(0, tty.text.width(text) - 1)), "")
    return prefix, text:sub(#prefix + 1)
end
local function shift(text: string): (string, string)
    for width = 1, tty.text.width(text) do
        local first = tty.text.truncate(text, width, "")
        if first ~= "" then return first, text:sub(#first + 1) end
    end
    return text, ""
end
function M.respond(value: State, event: unknown, panel: Panel): Result
    local state: State = {id = value.id, left = value.left, right = value.right, selected = value.selected, focus = value.focus, accent = value.accent, error = value.error}
    if type(event) ~= "table" then return {state = state, action = ""} end
    local action, inserted = "", ""
    if event.type == "key" and event.action ~= "release" then
        local key = event.key_type
        if key == "esc" or key == "escape" then action = "cancel"
        elseif key == "tab" then
            if event.shift == true then state.focus = state.focus == "text" and "cancel" or (state.focus == "cancel" and "save" or "text")
            else state.focus = state.focus == "text" and "save" or (state.focus == "save" and "cancel" or "text") end
        elseif key == "enter" then action = state.focus == "cancel" and "cancel" or "save"
        elseif state.focus ~= "text" then
            if key == "space" then action = state.focus == "cancel" and "cancel" or "save"
            elseif key == "left" or key == "right" then state.focus = state.focus == "save" and "cancel" or "save" end
        elseif event.ctrl == true and event.key == "a" then state.selected = true
        elseif key == "home" then state.right = state.left .. state.right; state.left = ""; state.selected = false
        elseif key == "end" then state.left = state.left .. state.right; state.right = ""; state.selected = false
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
            elseif key == "backspace" then state.left = pop(state.left)
            else local _, rest = shift(state.right); state.right = rest end
            state.selected = false
        elseif key == "space" and event.ctrl ~= true and event.alt ~= true then inserted = " "
        elseif key == "runes" and event.ctrl ~= true and event.alt ~= true and type(event.key) == "string" then inserted = event.key end
    elseif event.type == "paste" and state.focus == "text" and type(event.text) == "string" then inserted = event.text
    elseif event.type == "mouse" and event.action == "press" and event.button == "left"
        and type(event.x) == "number" then
        if panel.height >= 5 and event.y == panel.y + 3 and event.x >= panel.x + 2 and event.x < panel.x + panel.width - 2 then
            state.focus = "text"; state.selected = true
        elseif panel.height >= 7 and event.y == panel.y + 5 then
            if panel.width >= 12 and event.x >= panel.x + 2 and event.x < panel.x + 10 then action = "save"
            elseif event.x >= panel.x + 12 and event.x < panel.x + 22 and panel.width >= 24 then action = "cancel" end
        end
    end
    if inserted ~= "" then
        local left, right = state.selected and "" or state.left, state.selected and "" or state.right
        if inserted:find("%c") then state.error = "Use a single-line label"
        elseif #left + #right + #inserted > 80 then state.error = "Use a shorter label"
        else state.left = left .. inserted; state.right = right; state.selected = false; state.error = "" end
    end
    return {state = state, action = action}
end
function M.draw(canvas: tty.Canvas, state: State, width: integer, height: integer, preferences: appearance.Preferences): {x: integer, y: integer, visible: boolean}
    local p = M.panel(width, height)
    local theme = appearance.theme(preferences.theme)
    local style = appearance.style(theme.text, theme.surface)
    for y = p.y, p.y + p.height - 1 do canvas:put(p.x, y, style .. string.rep(" ", p.width) .. "\27[0m", p.width) end
    local function put(y: integer, text: string, color: string)
        if y < p.y + p.height and p.width > 4 then
            canvas:put(p.x + 2, y, appearance.style(color, theme.surface) .. tty.text.truncate(text, p.width - 4, "…") .. "\27[0m", p.width - 4)
        end
    end
    if p.width >= 2 and p.height >= 2 then
        canvas:put(p.x, p.y, style .. "╭" .. string.rep("─", p.width - 2) .. "╮\27[0m", p.width)
        canvas:put(p.x, p.y + p.height - 1, style .. "╰" .. string.rep("─", p.width - 2) .. "╯\27[0m", p.width)
        for y = p.y + 1, p.y + p.height - 2 do
            canvas:put(p.x, y, style .. "│\27[0m", 1); canvas:put(p.x + p.width - 1, y, style .. "│\27[0m", 1)
        end
    end
    put(p.y + 1, "Rename application", theme.accent)
    local room = math.floor(math.max(0, p.width - 5))
    local left_width = tty.text.width(state.left)
    local offset = math.floor(math.max(0, left_width - room + 1))
    local text = tty.text.cut(state.left .. state.right, offset, offset + room)
    if room > 0 and p.height >= 5 then
        local selected = state.selected and state.focus == "text"
        local fg = selected and appearance.selection_text(theme) or theme.text
        local bg = selected and theme.accent or theme.surface
        canvas:put(p.x + 2, p.y + 3, appearance.style(fg, bg) .. text .. "\27[0m", room)
    end
    if state.error ~= "" then put(p.y + 4, state.error, theme.accent)
    else put(p.y + 4, "Empty restores the application's title", theme.muted) end
    if p.height >= 7 then
        for index, item in ipairs({{id = "save", text = "[ Save ]"}, {id = "cancel", text = "[ Cancel ]"}}) do
            local x = p.x + 2 + (index - 1) * 10
            local room = math.floor(math.max(0, math.min(#item.text, p.x + p.width - 1 - x)))
            local fg = state.focus == item.id and appearance.selection_text(theme) or theme.text
            local bg = state.focus == item.id and theme.accent or theme.surface
            if room > 0 then canvas:put(x, p.y + 5, appearance.style(fg, bg) .. tty.text.truncate(item.text, room, "") .. "\27[0m", room) end
        end
    end
    return {x = p.x + 2 + left_width - offset, y = p.y + 3, visible = room > 0 and p.height >= 5 and not state.selected and state.focus == "text"}
end
return M

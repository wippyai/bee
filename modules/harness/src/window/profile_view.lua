-- MIT. Agent profile form rendering and input; persistence belongs to profile_form.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local editor = require("editor")
local forms = require("forms")
local M = {}
type Field = {kind: string, name: string, label: string, option_kind: string?, max_bytes: integer?}
type State = {form: forms.Form, title: string, guidance: string, option_text: {[string]: string}, selected: integer,
    status: string, confirming_remove: boolean}
type Frame = {rows: {string}, hits: {frame.Hit}}

function M.new(form: forms.Form): State
    local option_text: {[string]: string} = {}
    local options = editor.options(form.draft) or {}
    for _, option in ipairs(options) do
        if option.kind == "text" then
            option_text[option.name] = type(option.value) == "string" and option.value or ""
        end
    end
    return {form = form, title = form.draft.title, guidance = form.draft.instructions,
        option_text = option_text, selected = 1, status = "", confirming_remove = false}
end
local function fields(state: State): {Field}
    local result: {Field} = {{kind = "title", name = "", label = "Name"}}
    if state.form.draft._allowed.instructions then result[#result + 1] = {kind = "guidance", name = "", label = "Instructions"} end
    local options = editor.options(state.form.draft)
    for _, option in ipairs(options or {}) do
        result[#result + 1] = {kind = "option", name = option.name, option_kind = option.kind,
            max_bytes = option.max_bytes, label = option.name .. ": " .. (option.value == nil and "Default" or tostring(option.value))}
    end
    local tools = editor.tools(state.form.draft)
    for _, tool in ipairs(tools or {}) do
        result[#result + 1] = {kind = "tool", name = tool.name, label = (tool.selected and "[x] " or "[ ] ") .. tool.name}
    end
    return result
end
local function erase(value: string): string
    local index = #value
    while index > 1 do
        local byte = value:byte(index)
        if byte < 128 or byte >= 192 then break end
        index = index - 1
    end
    return value:sub(1, index - 1)
end
function M.action(state: State, action: string): string?
    if action == "cancel" then
        if state.confirming_remove then state.confirming_remove = false; return nil end
        return "cancel"
    end
    if action == "remove" then
        if state.form.revision < 1 or state.form.pending == "save" then return nil end
        if state.confirming_remove then return "remove" end
        state.confirming_remove = true
        return nil
    end
    if action == "save" then
        if state.confirming_remove then return nil end
        if state.form.pending then return state.form.pending end
        local named, name_error = editor.set_title(state.form.draft, state.title)
        if not named then state.status = name_error or "Invalid name"; return nil end
        local guided, guidance_error = editor.set_guidance(state.form.draft, state.guidance)
        if not guided then state.status = guidance_error or "Invalid instructions"; return nil end
        for name, value in pairs(state.option_text) do
            local changed, option_error = editor.set_text_option(state.form.draft, name, value)
            if not changed then state.status = option_error or "Invalid option"; return nil end
        end
        return "save"
    end
    return nil
end
function M.input(state: State, event: tty.TTYEvent, drawn: Frame): string?
    local listed = fields(state)
    if event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if hit and hit.kind == "field" then state.selected = hit.index
        elseif hit then return M.action(state, hit.kind) end
    elseif event.type == "key" and event.action == "press" then
        if event.key_type == "escape" or event.key_type == "esc" then return M.action(state, "cancel") end
        if state.confirming_remove then
            if event.key_type == "enter" then return M.action(state, "remove") end
            return nil
        end
        if event.ctrl and event.key == "s" then return M.action(state, "save") end
        if event.ctrl and event.key == "d" then return M.action(state, "remove") end
        if event.key_type == "tab" or event.key_type == "down" or event.key_type == "up" then
            local delta = (event.key_type == "up" or (event.key_type == "tab" and event.shift)) and -1 or 1
            state.selected = math.floor(((state.selected - 1 + delta) % #listed) + 1)
            return nil
        end
    end
    if state.form.pending or state.confirming_remove then return nil end
    local field = listed[state.selected]
    if not field then return nil end
    if field.kind == "tool" or (field.kind == "option" and field.option_kind == "enum") then
        if event.type == "key" and event.action == "press" and
            (event.key_type == "enter" or event.key_type == "space" or event.key == " " or event.key_type == "left" or event.key_type == "right") then
            local ok: boolean = false
            local err: string? = nil
            if field.kind == "tool" then ok, err = editor.toggle_tool(state.form.draft, field.name)
            else ok, err = editor.cycle_option(state.form.draft, field.name, event.key_type == "left" and -1 or 1) end
            state.status = ok and "" or (err or "Option is unavailable")
        end
        return nil
    end
    local value = field.kind == "title" and state.title
        or (field.kind == "option" and (state.option_text[field.name] or "") or state.guidance)
    local limit = field.kind == "title" and editor.MAX_TITLE_BYTES
        or (field.kind == "option" and (field.max_bytes or editor.MAX_INSTRUCTIONS_BYTES) or editor.MAX_INSTRUCTIONS_BYTES)
    if event.type == "paste" then value = value .. event.text
    elseif event.type == "key" and event.action == "press" then
        if event.ctrl and event.key == "u" then value = ""
        elseif event.key_type == "backspace" or event.key_type == "backspace2" then value = erase(value)
        elseif event.key_type == "enter" and field.kind == "guidance" then value = value .. "\n"
        elseif event.key_type == "space" and not event.ctrl and not event.alt then value = value .. " "
        elseif not event.ctrl and not event.alt and event.key ~= "" and not event.key:find("%c") then value = value .. event.key end
    end
    if #value > limit then state.status = "Text exceeds " .. tostring(limit) .. " bytes"; return nil end
    if field.kind == "title" then state.title = value
    elseif field.kind == "option" then state.option_text[field.name] = value
    else state.guidance = value end
    return nil
end

local HINTS = frame.hints({{key = "Tab", verb = "fields"}, {key = "Ctrl+S", verb = "save"}, {key = "Ctrl+D", verb = "remove"}, {key = "Esc", verb = "cancel"}})
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): Frame
    local painter = frame.new(width, height, preferences)
    frame.header(painter, state.form.revision > 0 and "EDIT AGENT PROFILE" or "NEW AGENT PROFILE")
    local listed = fields(state)
    local capacity = math.floor(math.max(0, height - 7))
    local window = frame.window(#listed, capacity, state.selected, 0)
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local field = listed[index]
        if not field then break end
        local label = field.label
        if field.kind == "title" then label = label .. ": " .. state.title
        elseif field.kind == "option" and field.option_kind == "text" then
            label = field.name .. ": " .. (state.option_text[field.name] or "Default")
        elseif field.kind == "guidance" then label = label .. ": " .. state.guidance:gsub("\r?\n", " ↵ ") end
        frame.row(painter, slot + 2, text.bound(label, 4096), index == state.selected, "field", index, "")
    end
    frame.line(painter, height - 3, state.confirming_remove and "Remove this profile? Enter confirms; Esc keeps it." or
        (state.form.pending and "Request submitted. Retry uses the same values." or "Instructions append to the harness. Saving does not launch."),
        state.confirming_remove and painter.theme.text or painter.theme.muted)
    if height >= 3 then
        local buttons: {frame.Button} = {{kind = "save", label = "Save", enabled = not state.confirming_remove and state.form.pending ~= "remove", primary = true}}
        if state.form.revision > 0 then
            buttons[#buttons + 1] = {kind = "remove", label = state.confirming_remove and "Confirm" or "Remove",
                enabled = state.form.pending ~= "save", primary = state.confirming_remove}
        end
        buttons[#buttons + 1] = {kind = "cancel", label = "Cancel", enabled = true}
        frame.actions(painter, height - 1, buttons)
    end
    frame.footer(painter, text.bound(state.status, 4096), HINTS)
    return {rows = frame.rows(painter), hits = painter.hits}
end
return M

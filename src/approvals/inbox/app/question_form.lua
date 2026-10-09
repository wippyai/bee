local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local forms = require("forms")
local typed_form = require("typed_form")
local model = require("model")
local lease_form = require("lease_form")
local M = {}
type State = {form: forms.Form, fields: {typed_form.Field}, view: model.ApprovalView, status: string}

function M.new(view: model.ApprovalView): State
    local declared, problem = typed_form.fields({{id = "answer", schema = view.response_schema or {}, has_default = false}}, {})
    local fields: {typed_form.Field}, widgets: {forms.Field} = {}, {}
    for _, field in ipairs(declared) do
        if field.kind ~= "object" or #field.choices > 0 then
            fields[#fields + 1] = field
            local label = model.text(field.id:gsub("^answer%.", ""), 64)
            if field.required then label = label .. " *" end
            local choices: {{label: string, value: string}} = {{label = "Choose", value = ""}}
            if #field.choices > 0 then
                for index, value in ipairs(field.choices) do choices[#choices + 1] = {label = model.text(typed_form.label(value)), value = tostring(index)} end
                widgets[#widgets + 1] = forms.field_select(field.id, label, choices, "")
            elseif field.kind == "boolean" then
                choices[#choices + 1] = {label = "Yes", value = "true"}
                choices[#choices + 1] = {label = "No", value = "false"}
                widgets[#widgets + 1] = forms.field_select(field.id, label, choices, "")
            else
                widgets[#widgets + 1] = forms.field_text(field.id, label, typed_form.buffer(field), {hint = model.text(field.description), max_length = 4096})
            end
        end
    end
    return {form = forms.form_new(widgets), fields = fields, view = view, status = problem or ""}
end

function M.answer(state: State): (unknown, string?)
    local answer: unknown = state.view.response_schema and state.view.response_schema.type == "object" and table.create(0, 1) or nil
    for index, field in ipairs(state.fields) do
        local input = forms.value(state.form.fields[index])
        if input ~= "" or field.required and field.kind == "string" then
            local value: unknown, problem: string?
            if #field.choices > 0 then value = field.choices[math.floor(tonumber(input) or 0)]
            else value, problem = typed_form.parse(field, input) end
            if problem then return nil, problem end
            answer = typed_form.assign(answer, field.path, value)
        end
    end
    local problem = typed_form.validate({id = "answer", schema = state.view.response_schema or {}, has_default = false}, answer)
    return answer, problem
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): lease_form.Frame
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "QUESTION", model.text(state.view.requester_id))
    local prompt: {string} = {}
    local remaining = model.text(state.view.prompt.text, 4096)
    local room = math.floor(math.max(1, width - 4))
    while remaining ~= "" do
        local line = tty.text.cut(remaining, 0, room)
        prompt[#prompt + 1] = line
        remaining = remaining:sub(#line + 1)
    end
    local row = 3
    for _, line in ipairs(prompt) do
        if row >= height - 4 then break end
        frame.put(painter, 2, row, line, width - 4, painter.theme.text)
        row = row + 1
    end
    local offset = math.floor(math.max(0, state.form.focus - math.max(1, height - row - 3)))
    for index = offset + 1, #state.form.fields do
        if row >= height - 2 then break end
        local rows = math.floor(math.min(forms.rows(state.form.fields[index]), height - row - 2))
        forms.draw(painter, {x = 2, y = row, width = math.floor(math.max(1, width - 4)), height = rows}, state.form, index)
        row = row + rows
    end
    frame.footer(painter, state.status, "Tab next · Ctrl+S answer · Esc back", nil, {
        {kind = "submit", label = "Send answer", enabled = true, primary = true},
        {kind = "cancel", label = "Back", enabled = true}})
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end

function M.input(state: State, event: tty.TTYEvent, drawn: lease_form.Frame): string?
    if event.type == "paste" then forms.key(state.form, event); return nil end
    return lease_form.input(state, event, drawn)
end

return M

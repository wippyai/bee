-- MIT. The lease request form on the forms kit: an expiry choice, a use
-- limit and up to three ceiling extras (a capability and its parameters).
-- It validates as the person types and yields one bounded Spec; nothing here
-- asks governance for anything.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local forms = require("forms")
local model = require("model")
local leases = require("leases")
local M = {}
M.EXTRAS = 3
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
type State = {form: forms.Form, view: model.ApprovalView, status: string}

local DURATIONS = {{label = "30 minutes", value = "1800"}, {label = "1 hour", value = "3600"},
    {label = "4 hours", value = "14400"}, {label = "24 hours", value = "86400"}, {label = "7 days", value = "604800"},
    {label = "30 days", value = "2592000"}, {label = "No expiry", value = "none"}}

local function values(form: forms.Form): (string, string, {{capability: string, parameters: string}})
    local extras: {{capability: string, parameters: string}} = {}
    for index = 1, M.EXTRAS do
        extras[index] = {capability = forms.value(form.fields[2 + index * 2 - 1]), parameters = forms.value(form.fields[2 + index * 2])}
    end
    return forms.value(form.fields[1]), forms.value(form.fields[2]), extras
end

function M.new(view: model.ApprovalView): State
    local refs: {form: forms.Form?} = {form = nil}
    local function guard(check: (forms.Form) -> string?): (forms.Field) -> string?
        return function(_field: forms.Field): string?
            local form = refs.form
            if not form then return nil end
            return check(form)
        end
    end
    local fields: {forms.Field} = {
        forms.field_select("ttl", "Expires", DURATIONS, "86400"),
        forms.field_number("applies", "Max applies", nil, {min = 1, max = 1000000, step = 1,
            validate = guard(function(form: forms.Form): string?
                local ttl, applies = values(form)
                if ttl == "none" and applies == "" then return "Choose an expiry or a use limit" end
                return nil
            end)}),
    }
    for index = 1, M.EXTRAS do
        local capability_index, parameter_index = 2 + index * 2 - 1, 2 + index * 2
        fields[capability_index] = forms.field_text("extra" .. tostring(index), "Extra " .. tostring(index), "",
            {placeholder = "capability.id", max_length = 160,
                validate = guard(function(form: forms.Form): string?
                    local capability = forms.value(form.fields[capability_index])
                    local parameters = forms.value(form.fields[parameter_index])
                    if capability == "" then
                        if parameters ~= "" then return "Name the capability" end
                        return nil
                    end
                    if not leases.capability_name(capability) then return "Use a capability id such as workspace.files.write" end
                    return nil
                end)})
        fields[parameter_index] = forms.field_text("params" .. tostring(index), "  parameters", "",
            {placeholder = "none, or key=value,key=a|b", max_length = 256,
                validate = guard(function(form: forms.Form): string?
                    local capability = forms.value(form.fields[capability_index])
                    local parameters = forms.value(form.fields[parameter_index])
                    if capability == "" then return nil end
                    if parameters == "" then return nil end
                    local _, parameter_error = leases.parse_parameters(parameters)
                    return parameter_error
                end)})
    end
    local form = forms.form_new(fields)
    refs.form = form
    return {form = form, view = view, status = ""}
end

-- submit: validate every field, then build the spec; the message names the
-- first problem.
function M.submit(state: State): (leases.Spec?, string?)
    if not forms.validate(state.form) then
        state.status = "Fix the marked fields"
        return nil, state.status
    end
    local ttl, applies, extras = values(state.form)
    local spec, spec_error = leases.spec(ttl, applies, extras)
    if not spec then state.status = spec_error or "Invalid lease"; return nil, state.status end
    state.status = ""
    return spec, nil
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): Frame
    local painter = frame.new(width, height, preferences)
    local footer_buttons: {frame.Button} = {}
    frame.header(painter, "LEASE REQUEST", model.text(state.view.proposal.ref, 60))
    local sizes: {integer} = {}
    for index, field in ipairs(state.form.fields) do sizes[index] = forms.rows(field) end
    local rects = frame.stack({x = 2, y = 3, width = math.floor(math.max(1, width - 2)), height = math.floor(math.max(1, height - 5))}, sizes, 0)
    for index, rect in ipairs(rects) do forms.draw(painter, rect, state.form, index) end
    if height >= 4 then
        footer_buttons = {
            {kind = "submit", label = "Request lease", enabled = forms.can_submit(state.form), primary = true},
            {kind = "cancel", label = "Cancel", enabled = true},
        }
    end
    frame.footer(painter, state.status, frame.hints({{key = "Tab", verb = "next"}, {key = "Ctrl+S", verb = "request"}, {key = "Esc", verb = "cancel"}}), nil, footer_buttons)
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end

-- input: one key or mouse event; "submit" and "cancel" come back for the app
-- to act on.
function M.input(state: State, event: tty.TTYEvent, drawn: Frame): string?
    if event.type == "mouse" and event.action == "wheel" then
        forms.scroll(state.form, (event.button == "wheel_up" or event.button == "up") and -1 or 1)
        return nil
    end
    if event.type == "mouse" and event.action == "press" and event.button == "left" then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if not hit then return nil end
        if hit.kind == "submit" or hit.kind == "cancel" then return hit.kind end
        forms.click(state.form, hit)
        return nil
    end
    if event.type ~= "key" or event.action == "release" then return nil end
    if event.key_type == "escape" or event.key_type == "esc" then return "cancel" end
    if event.ctrl == true and event.key == "s" then return "submit" end
    forms.key(state.form, event)
    return nil
end

return M

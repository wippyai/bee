# Reference application: deploy wizard

Demonstrates the input kit inside an application: a wizard strip over one forms.Form per step, focus order and mouse clicks routed through forms.key and forms.click, per-field validation before Next, and a confirmation modal on the last step. The model returns "done" from key when the user confirms. forms.field_number, forms.field_toggle, forms.key, forms.click, forms.validate, forms.rows, forms.draw, frame.steps, frame.stack, frame.modal, frame.button, frame.kv.

## Source

```lua
-- SPDX-License-Identifier: MIT
-- Reference: deploy wizard.
-- Demonstrates the input kit inside an application: a wizard strip over one
-- forms.Form per step, focus order and mouse clicks routed through forms.key
-- and forms.click, per-field validation before Next, and a confirmation modal
-- on the last step. The model returns "done" from key when the user confirms.
--
-- Library calls: forms.form_new, forms.field_text, forms.field_select,
-- forms.field_number, forms.field_toggle, forms.key, forms.click,
-- forms.validate, forms.rows, forms.draw, frame.steps, frame.stack,
-- frame.modal, frame.button, frame.kv.
local frame = require("frame")
local forms = require("forms")

local M = {}

type Model = {step: integer, target: forms.Form, rollout: forms.Form, confirming: boolean}

local STEPS = {"Target", "Rollout", "Confirm"}

function M.new(): Model
    return {step = 1, confirming = false,
        target = forms.form_new({
            forms.field_text("service", "Service", "edge-api", {required = true, max_length = 40}),
            forms.field_select("region", "Region", {{label = "eu-west", value = "eu-west"}, {label = "us-east", value = "us-east"}}, "eu-west"),
        }),
        rollout = forms.form_new({
            forms.field_number("replicas", "Replicas", 3, {required = true, min = 1, max = 64, step = 1, hint = "1-64"}),
            forms.field_toggle("canary", "Canary first", true),
        })}
end

local function current(model: Model): forms.Form?
    if model.step == 1 then return model.target end
    if model.step == 2 then return model.rollout end
    return nil
end

local function summary(model: Model): {frame.Entry}
    local entries: {frame.Entry} = {}
    for _, form in ipairs({model.target, model.rollout}) do
        for _, field in ipairs(form.fields) do entries[#entries + 1] = {label = field.label, value = forms.value(field)} end
    end
    return entries
end

-- Routes one tty event. Enter advances a valid step and opens the
-- confirmation on the last one; Esc goes back or dismisses the modal.
-- Returns "done" when the confirmation is accepted.
function M.key(model: Model, event: {[string]: unknown}): string?
    if event.type ~= "key" or event.action == "release" then return nil end
    local name = event.key_type
    if model.confirming then
        if name == "enter" then model.confirming = false; return "done" end
        if name == "esc" or name == "escape" then model.confirming = false end
        return nil
    end
    local form = current(model)
    if name == "enter" and (form == nil or forms.validate(form)) then
        if model.step < #STEPS then model.step = model.step + 1 else model.confirming = true end
    elseif (name == "esc" or name == "escape") and model.step > 1 then
        model.step = model.step - 1
    elseif form then
        forms.key(form, event)
    end
    return nil
end

-- Routes a resolved frame.hit; the modal buttons use kinds "confirm" and "dismiss".
function M.click(model: Model, hit: frame.Hit): string?
    if hit.kind == "confirm" then model.confirming = false; return "done" end
    if hit.kind == "dismiss" then model.confirming = false; return nil end
    local form = current(model)
    if form then forms.click(form, hit) end
    return nil
end

function M.draw(painter: frame.Painter, work: frame.Rect, model: Model)
    local parts = frame.stack(work, {1, 0}, 1)
    frame.steps(painter, parts[1].y, STEPS, model.step)
    local body = parts[2]
    local form = current(model)
    if form then
        local heights: {integer} = {}
        for index, field in ipairs(form.fields) do heights[index] = forms.rows(field) end
        for index, rect in ipairs(frame.stack(body, heights, 1)) do forms.draw(painter, rect, form, index) end
    else
        frame.kv(painter, body.y, body.y + body.height - 1, {entries = summary(model), selected = 0, offset = 0})
    end
    if not model.confirming then return end
    local inner = frame.modal(painter, 46, 7, "Deploy " .. forms.value(model.target.fields[1]))
    if inner.height < 4 then return end
    frame.put(painter, inner.x, inner.y, "Roll out to " .. forms.value(model.target.fields[2]) .. "?", inner.width)
    local y = inner.y + inner.height - 1
    local x = frame.button(painter, inner.x, y, {kind = "confirm", key = "Enter", label = "Deploy", enabled = true, primary = true})
    frame.button(painter, x, y, {kind = "dismiss", key = "Esc", label = "Cancel", enabled = true})
end

return M
```

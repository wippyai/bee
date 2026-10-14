-- SPDX-License-Identifier: MIT

local forms = require("forms")
local frame = require("frame")
local appearance = require("appearance")
local profiles = require("profiles")
local M = {}
type State = {fields: {forms.TextField}, selected: integer, status: string}
local labels = {"Name (optional)", "Role (optional)", "Folder root (optional)", "Folder path (optional)"}
function M.new(): State
    return {fields = {forms.text_new("", "", 80, false), forms.text_new("", "", 256, false),
        forms.text_new("", "", 512, false), forms.text_new("", "", 512, false)}, selected = 1, status = ""}
end
function M.value(state: State): (profiles.Overrides?, string?)
    local raw: {[string]: unknown} = {}
    local values: {string} = {}
    for _, field in ipairs(state.fields) do values[#values + 1] = field.value end
    if values[1] ~= "" then raw.name = values[1] end
    if values[2] ~= "" then raw.role = values[2] end
    if values[3] ~= "" or values[4] ~= "" then
        raw.workdir = {root_ref = values[3] ~= "" and values[3] or "bee.node:machine", path = values[4]}
    end
    return profiles.overrides(raw)
end
function M.input(state: State, event: {[string]: unknown}, drawn: frame.View?): string?
    if event.type == "mouse" and event.action == "press" and event.button == "left" and drawn then
        local hit = frame.hit(drawn.hits, math.floor(tonumber(event.x) or 0), math.floor(tonumber(event.y) or 0))
        if not hit then return nil end
        if hit.kind == "cancel" then return "cancel" end
        if hit.kind ~= "open" then return nil end
        event = {type = "key", action = "press", key_type = "enter"}
    end
    if event.type == "key" and event.action ~= "press" then return nil end
    if event.key_type == "escape" or event.key_type == "esc" then return "cancel" end
    if event.key_type == "tab" then state.selected = state.selected % 4 + 1; return nil end
    if event.key_type == "enter" then
        local value, err = M.value(state)
        if value then return "open" end
        state.status = err or "Invalid launch options"; return nil
    end
    if forms.text_key(state.fields[state.selected], event) then state.status = "" end
    return nil
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): frame.View
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "START AGENT")
    for index, label in ipairs(labels) do
        frame.line(painter, index + 2, (state.selected == index and "› " or "  ") .. label .. ": " .. state.fields[index].value, painter.theme.text)
    end
    frame.footer(painter, state.status, frame.hints({{key = "Tab", verb = "field"}}), nil, {
        {kind = "open", key = "Enter", label = "Start agent", enabled = true, primary = true},
        {kind = "cancel", key = "Esc", label = "Cancel", enabled = true},
    })
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M

local bounds = require("bounds")
local frame = require("frame")
local appearance = require("appearance")
local profiles = require("profiles")
local M = {}
type State = {values: {string}, selected: integer, status: string}
local labels = {"Name (optional)", "Role (optional)", "Folder root (optional)", "Folder path (optional)"}
function M.new(): State return {values = {"", "", "", ""}, selected = 1, status = ""} end
function M.value(state: State): (profiles.Overrides?, string?)
    local raw: {[string]: unknown} = {}
    if state.values[1] ~= "" then raw.name = state.values[1] end
    if state.values[2] ~= "" then raw.role = state.values[2] end
    if state.values[3] ~= "" or state.values[4] ~= "" then
        raw.workdir = {root_ref = state.values[3] ~= "" and state.values[3] or "bee.node:machine", path = state.values[4]}
    end
    return profiles.overrides(raw)
end
function M.input(state: State, event: {[string]: unknown}): string?
    if event.type ~= "key" or event.action ~= "press" then return nil end
    if event.key_type == "escape" or event.key_type == "esc" then return "cancel" end
    if event.key_type == "tab" then state.selected = state.selected % 4 + 1; return nil end
    if event.key_type == "enter" then
        local value, err = M.value(state)
        if value then return "open" end
        state.status = err or "Invalid launch options"; return nil
    end
    local value = state.values[state.selected]
    if event.key_type == "backspace" then value = value:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif not event.ctrl and not event.alt then
        local addition = bounds.text(event.key, 4096)
        if addition and not addition:find("%c") then value = value .. addition end
    end
    local maximum = state.selected == 1 and 80 or state.selected == 2 and 256 or 512
    if #value <= maximum then state.values[state.selected] = value end
    return nil
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: State): frame.View
    local painter = frame.new(width, height, preferences)
    frame.header(painter, "OPEN AGENT")
    for index, label in ipairs(labels) do
        frame.line(painter, index + 2, (state.selected == index and "› " or "  ") .. label .. ": " .. state.values[index], painter.theme.text)
    end
    frame.line(painter, 8, state.status, painter.theme.text)
    frame.footer(painter, "", "Tab changes field · Enter opens · Esc cancels")
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M

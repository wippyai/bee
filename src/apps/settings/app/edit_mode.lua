-- MIT
local forms = require("forms")
local bounds = require("bounds")
local profiles = require("profiles")
local kernel = require("kernel")
local super_edit = require("super_edit")
local time = require("time")
local M = {}
type Area = {id: string, title: string}
type Grant = {area: string, expires_at: string}
type State = {areas: {Area}, grants: {Grant}, form: forms.Form?, problem: string}
function M.new(): State return {areas = {}, grants = {}, form = nil, problem = ""} end
function M.load(state: State, workspace: string, apps: unknown, configuration: unknown, protection: unknown): string?
    local manifest, manifest_error = kernel.decode(protection)
    local decoded, decode_error = profiles.decode(configuration)
    local installed, apps_error = bounds.dense_list(apps, 128, "installed apps")
    state.areas, state.grants = {}, {}
    if not manifest or not decoded or not installed then
        state.problem = manifest_error or decode_error or apps_error or "Editing areas are unavailable"
        return state.problem
    end
    local names: {[string]: string} = {}
    local function offer(id: string, title: string)
        if not super_edit.is_kernel(id, manifest) then names[id] = title end
    end
    for _, opened in ipairs(manifest.super_edit) do
        if opened == "bee.shell" then offer(opened, "Desktop") end
    end
    for _, raw in ipairs(installed) do
        local app = bounds.object(raw)
        local id = app and bounds.id(app.id)
        local namespace = id and id:match("^([^:]+):")
        if namespace then
            for _, opened in ipairs(manifest.super_edit) do
                if namespace == opened or namespace:sub(1, #opened + 1) == opened .. "." then namespace = opened; break end
            end
            offer(namespace, app and bounds.text(app.title, 160) or namespace)
        end
    end
    for id, title in pairs(names) do state.areas[#state.areas + 1] = {id = id, title = title} end
    table.sort(state.areas, function(a: Area, b: Area): boolean return a.title < b.title end)
    for _, profile in ipairs(decoded.profiles) do
        local expires = profile.expires_at ~= "" and time.parse("2006-01-02T15:04:05.000Z07:00", profile.expires_at) or nil
        if profile.workspace_id == workspace and profile.super_edit and expires and expires:after(time.now()) then
            state.grants[#state.grants + 1] = {area = names[profile.source_workspace] or profile.source_workspace, expires_at = profile.expires_at}
        end
    end
    table.sort(state.grants, function(a: Grant, b: Grant): boolean return a.area < b.area end)
    state.problem = ""
    return nil
end
function M.enable(state: State)
    local options: {forms.Option} = {}
    for _, area in ipairs(state.areas) do options[#options + 1] = {label = area.title, value = area.id} end
    state.form = forms.form_new({
        forms.field_select("area", "Area", options, options[1] and options[1].value or "", {required = true}),
        forms.field_select("duration", "Duration", {{label = "1 hour", value = "1h"}, {label = "8 hours", value = "8h"},
            {label = "24 hours", value = "24h"}}, "1h"),
    })
end
function M.request(state: State): (string?, string?)
    local form = state.form
    if not form or #state.areas == 0 then return nil, "No editable areas are installed" end
    if not forms.validate(form) then return nil, "Choose an area and a duration" end
    local area = forms.value(form.fields[1])
    local duration = forms.value(form.fields[2])
    for _, choice in ipairs(state.areas) do
        if choice.id == area then return area .. " --for " .. duration, nil end
    end
    return nil, "Choose an installed area"
end
return M

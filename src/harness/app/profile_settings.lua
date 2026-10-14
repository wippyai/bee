-- SPDX-License-Identifier: MIT
-- Docker limit form values. Empty values inherit defaults; editing limits
-- never replaces other saved Docker requests.
local bounds = require("bounds")
local editor = require("editor")
local M = {}
type Field = {kind: string, name: string, label: string}
type Values = {[string]: string}
type Object = {[string]: unknown}
local DOCKER = {{name = "memory_bytes", label = "Docker memory (bytes)"},
    {name = "cpu_millicpus", label = "Docker CPU (millicpus)"}, {name = "pids", label = "Docker process limit"}}
function M.fields(profile: editor.Draft): {Field}
    local result: {Field} = {}
    if profile.placement and profile.placement.kind == "docker" then
        for _, limit in ipairs(DOCKER) do
            result[#result + 1] = {kind = "settings", name = "docker." .. limit.name, label = limit.label}
        end
    end
    return result
end
function M.read(profile: editor.Draft): Values
    local result: Values = {}
    local placement = profile.placement
    local limits = placement and placement.kind == "docker" and placement.overrides and bounds.object(placement.overrides.limits)
    for _, limit in ipairs(DOCKER) do
        local value = limits and limits[limit.name]
        result["docker." .. limit.name] = type(value) == "number" and tostring(value) or ""
    end
    return result
end
local function amount(text: string?, label: string): (number?, string?)
    if text == nil or text == "" then return nil, nil end
    local value = tonumber(text)
    if not value or value <= 0 or value ~= value or value == math.huge or value > 9007199254740991 or value ~= math.floor(value) then
        return nil, label .. " must be a positive whole number"
    end
    return value, nil
end
function M.apply(profile: editor.Draft, values: Values): string?
    local placement = profile.placement
    if not placement or placement.kind ~= "docker" then return nil end
    local overrides: Object = {}
    for key, value in pairs(placement.overrides or {}) do overrides[key] = value end
    local limits: Object = {}
    for _, limit in ipairs(DOCKER) do
        local value, err = amount(values["docker." .. limit.name], limit.label)
        if err then return err end
        if value then limits[limit.name] = value end
    end
    overrides.limits = next(limits) and limits or nil
    placement.overrides = next(overrides) and overrides or nil
    return nil
end
return M

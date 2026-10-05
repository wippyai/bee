-- SPDX-License-Identifier: MIT
-- Named form values use the canonical profile decoders at save. Empty values
-- inherit defaults; editing limits never replaces other saved Docker requests.
local budgets = require("budgets")
local bounds = require("bounds")
local editor = require("editor")
local M = {}
type Field = {kind: string, name: string, label: string}
type Values = {[string]: string}
type Object = {[string]: unknown}
local LIMITS = {{name = "wall_time_ms", label = "Time limit (ms)"},
    {name = "provider_steps", label = "Provider step limit"}, {name = "tool_calls", label = "Tool call limit"},
    {name = "tokens", label = "Token limit"}, {name = "cost_usd", label = "Cost limit (USD)"}}
local DOCKER = {{name = "memory_bytes", label = "Docker memory (bytes)"},
    {name = "cpu_millicpus", label = "Docker CPU (millicpus)"}, {name = "pids", label = "Docker process limit"}}
function M.fields(profile: editor.Draft): {Field}
    local result: {Field} = {}
    for _, scope in ipairs({"turn", "session"}) do
        for _, limit in ipairs(LIMITS) do
            result[#result + 1] = {kind = "settings", name = scope .. "." .. limit.name,
                label = (scope == "turn" and "Turn " or "Session ") .. limit.label}
        end
    end
    result[#result + 1] = {kind = "settings", name = "quiet_period_ms", label = "Stall quiet period (ms)"}
    if profile.placement and profile.placement.kind == "docker" then
        for _, limit in ipairs(DOCKER) do
            result[#result + 1] = {kind = "settings", name = "docker." .. limit.name, label = limit.label}
        end
    end
    return result
end
function M.read(profile: editor.Draft): Values
    local result: Values = {}
    for _, scope in ipairs({"turn", "session"}) do
        local budget: budgets.Budget? = nil
        if profile.budgets then
            if scope == "turn" then budget = profile.budgets.turn else budget = profile.budgets.session end
        end
        for _, limit in ipairs(LIMITS) do
            local value = budget and budget[limit.name]
            result[scope .. "." .. limit.name] = value and tostring(value) or ""
        end
    end
    local quiet = profile.supervision and profile.supervision.quiet_period_ms
    result.quiet_period_ms = quiet and tostring(quiet) or ""
    local placement = profile.placement
    local limits = placement and placement.kind == "docker" and placement.overrides and bounds.object(placement.overrides.limits)
    for _, limit in ipairs(DOCKER) do
        local value = limits and limits[limit.name]
        result["docker." .. limit.name] = type(value) == "number" and tostring(value) or ""
    end
    return result
end
local function amount(text: string?, label: string, fractional: boolean?): (number?, string?)
    if text == nil or text == "" then return nil, nil end
    local value = tonumber(text)
    if not value or value <= 0 or value ~= value or value == math.huge or value > 9007199254740991
        or (not fractional and value ~= math.floor(value)) then
        return nil, label .. (fractional and " must be a positive amount" or " must be a positive whole number")
    end
    return value, nil
end
function M.apply(profile: editor.Draft, values: Values): string?
    local requested: Object = {}
    for _, scope in ipairs({"turn", "session"}) do
        local selected: Object = {}
        for _, limit in ipairs(LIMITS) do
            local value, err = amount(values[scope .. "." .. limit.name], limit.label, limit.name == "cost_usd")
            if err then return err end
            if value then selected[limit.name] = value end
        end
        if next(selected) then requested[scope] = selected end
    end
    local admitted, budget_error = budgets.budgets(next(requested) and requested or nil)
    if budget_error then return budget_error end
    local quiet, quiet_error = amount(values.quiet_period_ms, "Stall quiet period (ms)")
    if quiet_error then return quiet_error end
    local supervision, supervision_error = budgets.supervision({quiet_period_ms = quiet,
        on_stall = profile.supervision and profile.supervision.on_stall})
    if supervision_error then return supervision_error end
    local placement = profile.placement
    local overrides: Object? = nil
    if placement and placement.kind == "docker" then
        overrides = {}
        for key, value in pairs(placement.overrides or {}) do overrides[key] = value end
        local limits: Object = {}
        for _, limit in ipairs(DOCKER) do
            local value, err = amount(values["docker." .. limit.name], limit.label)
            if err then return err end
            if value then limits[limit.name] = value end
        end
        overrides.limits = next(limits) and limits or nil
    end
    profile.budgets = admitted
    profile.supervision = supervision and next(supervision) and supervision or nil
    if placement and placement.kind == "docker" then placement.overrides = overrides and next(overrides) and overrides or nil end
    return nil
end
return M

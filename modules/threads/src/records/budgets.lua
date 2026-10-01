-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Budget = {wall_time_ms: integer?, provider_steps: integer?, tool_calls: integer?, tokens: integer?, cost_usd: number?}
type Budgets = {turn: Budget?, session: Budget?}
type Supervision = {quiet_period_ms: integer?, on_stall: "report" | "cancel_work"?}
function M.decode(value: unknown): (Budget?, string?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"wall_time_ms", "provider_steps", "tool_calls", "tokens", "cost_usd"}) then
        return nil, "budget must name wall_time_ms, provider_steps, tool_calls, tokens or cost_usd"
    end
    local result: Budget = {}
    local supplied = false
    for _, field in ipairs({"wall_time_ms", "provider_steps", "tool_calls", "tokens"}) do
        if raw[field] ~= nil then
            local amount = bounds.count(raw[field])
            if not amount or amount < 1 then return nil, "budget." .. field .. " must be a positive safe integer" end
            if field == "wall_time_ms" then result.wall_time_ms = amount
            elseif field == "provider_steps" then result.provider_steps = amount
            elseif field == "tool_calls" then result.tool_calls = amount
            else result.tokens = amount end
            supplied = true
        end
    end
    if raw.cost_usd ~= nil then
        local amount = raw.cost_usd
        if type(amount) ~= "number" or amount <= 0 or amount ~= amount or amount == math.huge then
            return nil, "budget.cost_usd must be a positive finite number"
        end
        result.cost_usd = amount
        supplied = true
    end
    if not supplied then return nil, "budget must set at least one limit" end
    return result, nil
end
function M.budgets(value: unknown): (Budgets?, string?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"turn", "session"}) then return nil, "budgets must name only turn and session" end
    local turn, turn_error = M.decode(raw.turn)
    if turn_error then return nil, "budgets.turn: " .. turn_error end
    local session, session_error = M.decode(raw.session)
    if session_error then return nil, "budgets.session: " .. session_error end
    if not turn and not session then return nil, "budgets must set turn or session" end
    return {turn = turn, session = session}, nil
end
function M.supervision(value: unknown): (Supervision?, string?)
    if value == nil then return nil, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"quiet_period_ms", "on_stall"}) then return nil, "supervision must name quiet_period_ms and on_stall" end
    local quiet: integer? = nil
    if raw.quiet_period_ms ~= nil then
        quiet = bounds.count(raw.quiet_period_ms)
        if not quiet or quiet < 1 then return nil, "supervision.quiet_period_ms must be a positive safe integer" end
    end
    local action: "report" | "cancel_work"? = nil
    if raw.on_stall == "report" then action = "report"
    elseif raw.on_stall == "cancel_work" then action = "cancel_work"
    elseif raw.on_stall ~= nil then return nil, "supervision.on_stall must be report or cancel_work" end
    return {quiet_period_ms = quiet, on_stall = action}, nil
end
function M.minimum(left: Budget?, right: Budget?): Budget?
    if not left then return right end
    if not right then return left end
    local result: Budget = {}
    for _, field in ipairs({"wall_time_ms", "provider_steps", "tool_calls", "tokens", "cost_usd"}) do
        local a, b = left[field], right[field]
        local amount = a and b and math.min(a, b) or a or b
        if field == "cost_usd" then result.cost_usd = amount
        elseif amount ~= nil then
            local integer = math.floor(amount)
            if field == "wall_time_ms" then result.wall_time_ms = integer
            elseif field == "provider_steps" then result.provider_steps = integer
            elseif field == "tool_calls" then result.tool_calls = integer
            else result.tokens = integer end
        end
    end
    return result
end
function M.accounting(limits: Budgets?, coverage: unknown, presentation: string?, codec: string?): string?
    if not limits then return nil end
    if presentation == "window" then return "budgets: window hooks cannot account provider usage or prove budget cancellation" end
    local declared = bounds.object(coverage)
    for _, scope in ipairs({"turn", "session"}) do
        local ceiling = scope == "turn" and limits.turn or limits.session
        if ceiling then
            for _, unit in ipairs({"cost_usd", "tokens", "tool_calls", "wall_time_ms", "provider_steps"}) do
                if ceiling[unit] ~= nil then
                    if unit == "cost_usd" or not declared or (unit ~= "provider_steps" and declared[unit] ~= true)
                        or (unit == "provider_steps" and declared.provider_steps ~= "agent_turn") then
                        return "budgets." .. scope .. "." .. unit .. ": usage codec " .. (codec or "unknown") .. " cannot account this unit"
                    end
                end
            end
        end
    end
    return nil
end
return M

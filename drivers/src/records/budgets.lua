-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Budget = {wall_time_ms: integer?, provider_steps: integer?, tool_calls: integer?, tokens: integer?, cost_usd: number?}
type Budgets = {turn: Budget?, session: Budget?}
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
return M

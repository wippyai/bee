-- MIT. Decode optional per-Work limits and count the normalized live turn events.
local bounds = require("bounds")
local budget_values = require("budget_values")
local M = {}

type Budget = budget_values.Budget
type Supervision = budget_values.Supervision
M.supervision = budget_values.supervision
type Counters = {turns: integer, tokens: integer, tool_calls: integer}

function M.decode(value: unknown): (Budget?, string?)
    local budget, err = budget_values.decode(value)
    if budget and budget.cost_usd then return nil, "cost_usd requires trustworthy provider cost accounting" end
    return budget, err
end

function M.new(): Counters
    return {turns = 0, tokens = 0, tool_calls = 0}
end

local function add(left: integer, right: integer): integer
    return math.floor(math.min(bounds.MAX_SAFE_INTEGER, left + right))
end

function M.observe(counters: Counters, value: unknown)
    local event = bounds.object(value)
    local data = event and bounds.object(event.data)
    if data and data.type == "tool.call" then counters.tool_calls = add(counters.tool_calls, 1); return end
    if not data or data.type ~= "turn.signal" then return end
    if data.phase == "started" then
        counters.turns = add(counters.turns, 1)
    elseif data.phase == "ended" then
        local usage = bounds.object(data.usage)
        if usage then
            local input = bounds.count(usage.input_tokens) or 0
            local output = bounds.count(usage.output_tokens) or 0
            counters.tokens = add(counters.tokens, add(input, output))
        end
    end
end

function M.exceeded(budget: Budget?, counters: Counters, elapsed_ms: integer): string?
    if not budget then return nil end
    if budget.wall_time_ms ~= nil and elapsed_ms >= budget.wall_time_ms then return "wall_time_ms" end
    if budget.provider_steps ~= nil and counters.turns > budget.provider_steps then return "provider_steps" end
    if budget.tool_calls ~= nil and counters.tool_calls > budget.tool_calls then return "tool_calls" end
    if budget.tokens ~= nil and counters.tokens > budget.tokens then return "tokens" end
    return nil
end

return M

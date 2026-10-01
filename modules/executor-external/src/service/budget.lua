-- MIT. Decode optional per-Work limits and count the normalized live turn events.
local bounds = require("bounds")
local M = {}

type Budget = {max_turns: integer?, max_tokens: integer?, wall_time_ms: integer?}
type Counters = {turns: integer, tokens: integer}

function M.decode(value: unknown): (Budget?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, "budget must be an object" end
    local unknown = bounds.fields(object, {"max_turns", "max_tokens", "wall_time_ms"})
    if unknown then return nil, "budget has unknown field " .. unknown end
    local result: Budget = {}
    for _, name in ipairs({"max_turns", "max_tokens", "wall_time_ms"}) do
        local raw = object[name]
        if raw ~= nil then
            local selected = bounds.count(raw)
            if not selected then return nil, "budget." .. name .. " must be a nonnegative integer" end
            if name == "max_turns" then result.max_turns = selected
            elseif name == "max_tokens" then result.max_tokens = selected
            else result.wall_time_ms = selected end
        end
    end
    if result.max_turns == nil and result.max_tokens == nil and result.wall_time_ms == nil then
        return nil, "budget must set at least one limit"
    end
    return result, nil
end

function M.new(): Counters
    return {turns = 0, tokens = 0}
end

local function add(left: integer, right: integer): integer
    return math.floor(math.min(bounds.MAX_SAFE_INTEGER, left + right))
end

function M.observe(counters: Counters, value: unknown)
    local event = bounds.object(value)
    local data = event and bounds.object(event.data)
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
    if budget.max_turns ~= nil and counters.turns > budget.max_turns then return "max_turns" end
    if budget.max_tokens ~= nil and counters.tokens > budget.max_tokens then return "max_tokens" end
    return nil
end

return M

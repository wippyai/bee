-- MIT. Shared host-selected turn budget bounds and terminal wording.
local bounds = require("bounds")
local M = {}
M.MAX = 128

local OPTION_NAMES: {[string]: boolean} = {turn_budget = true, max_turns = true, max_steps = true}

function M.is_option(name: string): boolean
    return OPTION_NAMES[name] == true
end

function M.decode(value: unknown, label: string?): (integer?, string?)
    if value == nil then return nil, nil end
    local selected = bounds.integer(value)
    if not selected or selected < 1 or selected > M.MAX then
        return nil, (label or "turn_budget") .. " must be between 1 and " .. tostring(M.MAX)
    end
    return selected, nil
end

function M.message(budget: integer?): string
    if budget then return "turn budget of " .. tostring(budget) .. " reached" end
    return "turn budget reached"
end

return M

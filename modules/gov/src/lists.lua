-- MIT. Shared bounded decoders for Governance list values.
local bounds = require("bounds")

local M = {}

function M.strings(raw: unknown, label: string, maximum: integer): ({string}?, string?)
    if raw == nil then return {}, nil end
    local rows, rows_error = bounds.dense_list(raw, maximum, label)
    if not rows then return nil, rows_error end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, value in ipairs(rows) do
        local item = bounds.id(value)
        if not item or seen[item] then return nil, label .. " contains an invalid or duplicate value" end
        seen[item], result[#result + 1] = true, item
    end
    table.sort(result)
    return result, nil
end

return M

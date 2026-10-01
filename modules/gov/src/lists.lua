-- MIT. Shared bounded decoders for Governance list values.
local bounds = require("bounds")

local M = {}

function M.dense(raw: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a list" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds its bound" end
    local result: {unknown} = {}
    for index = 1, count do
        local item = raw[index]
        if item == nil then return nil, label .. " must be a dense list" end
        result[index] = item
    end
    return result, nil
end

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

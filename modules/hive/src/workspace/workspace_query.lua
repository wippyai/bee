-- MIT. Shared bounded query accepted by Hive workspace catalog readers.
local bounds = require("bounds")

type Query = {label: string?, after: string?, limit: integer}

local M = {}
M.MAX_PAGE = 50
M.MAX_LABEL = 240
M.MAX_CURSOR = 2200

function M.decode(value: unknown, extra_fields: {string}?): (Query?, string?)
    local object = value == nil and {} or bounds.object(value)
    if not object then return nil, "input must be an object" end

    local fields = {"label", "after", "limit"}
    for _, name in ipairs(extra_fields or {}) do fields[#fields + 1] = name end
    local extra = bounds.fields(object, fields)
    if extra then return nil, extra end

    local query: Query = {label = nil, after = nil, limit = M.MAX_PAGE}
    if object.label ~= nil then
        local label = bounds.line(object.label, M.MAX_LABEL)
        if not label then return nil, "label must be one nonempty line" end
        query.label = label
    end
    if object.after ~= nil then
        local after = bounds.line(object.after, M.MAX_CURSOR)
        if not after then return nil, "after must be a cursor this operation returned" end
        query.after = after
    end
    if object.limit ~= nil then
        local limit = bounds.integer(object.limit)
        if not limit or limit < 1 or limit > M.MAX_PAGE then
            return nil, "limit must be between 1 and " .. tostring(M.MAX_PAGE)
        end
        query.limit = limit
    end
    return query, nil
end

return M

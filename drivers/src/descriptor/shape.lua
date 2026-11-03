-- MIT. Shared decoding primitives for CLI descriptor declarations.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}

function M.object(value: unknown, label: string): (Object?, string?)
    local decoded = bounds.object(value)
    if not decoded then return nil, label .. " must be an object" end
    return decoded, nil
end

function M.sequence(value: unknown, label: string, limit: integer): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be an array" end
    local source = value
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, label .. " must be a dense array" end
        count = count + 1
        if count > limit then return nil, label .. " exceeds its item limit" end
    end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense array" end
        result[index] = source[index]
    end
    return result, nil
end

function M.safe_relative(path: string): boolean
    if path == "" or path:sub(1, 1) == "/" or path:find("[%z\\\\]") then return false end
    for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return false end end
    return true
end

return M

-- MIT. Bounded launch values; applications decode their own argument semantics.
local M = {}
function M.decode(value: unknown): {string}?
    if value == nil then return {} end
    if type(value) ~= "table" then return nil end
    local count, bytes = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local result: {string} = {}
    for index = 1, count do
        local item: unknown = value[index]
        if type(item) ~= "string" or #item > 1024 or item:find("%c") then return nil end
        bytes = bytes + #item
        if bytes > 8192 then return nil end
        result[index] = item
    end
    return result
end
-- Length framing keeps request identity unambiguous, including empty values.
function M.fingerprint(values: {string}): string
    local result = ""
    for _, value in ipairs(values) do result = result .. tostring(#value) .. ":" .. value end
    return result
end
return M

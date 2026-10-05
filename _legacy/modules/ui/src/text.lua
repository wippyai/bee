-- MIT. Display text from another authority: every control character
-- replaced, the length bounded on a character boundary. Grants nothing.
local M = {}
function M.bound(value: unknown, limit: integer): string
    local raw = value == nil and "" or tostring(value)
    local clean = raw:gsub("[%z\1-\31\127]", " ")
    if #clean <= limit then return clean end
    local cut = limit
    while cut > 0 and clean:byte(cut + 1) and clean:byte(cut + 1) >= 0x80 and clean:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    return clean:sub(1, cut) .. "…"
end
return M

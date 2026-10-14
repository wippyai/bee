local M = {}
function M.message(name: string): string
    local cleaned = name:match("^%s*(.-)%s*$") or ""
    if cleaned == "" then cleaned = "Bee" end
    return "Hello, " .. cleaned
end
return M

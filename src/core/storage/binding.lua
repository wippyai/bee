-- MIT. Core stores accept registry resources, never caller-supplied file paths.
local M = {}
function M.database(kind: "client" | "workspace", value: unknown): string?
    local default = "bee:" .. kind .. "_db"
    if value == nil or value == default then return default end
    if type(value) ~= "string" or #value > 160 then return nil end
    local prefix = "bee." .. kind .. ".db:"
    if value:sub(1, #prefix) ~= prefix then return nil end
    local name = value:sub(#prefix + 1)
    if name == "" or not name:match("^[%w_%-]+$") then return nil end
    return value
end
return M

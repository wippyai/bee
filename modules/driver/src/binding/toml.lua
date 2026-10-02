-- MIT. Encode a TOML basic string, escaping quotes, slashes and control bytes.
local M = {}

function M.string(value: string): string
    local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"')
    escaped = escaped:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    escaped = escaped:gsub("[%z\1-\8\11\12\14-\31\127]", function(character: string): string
        return string.format("\\u%04X", character:byte())
    end)
    return '"' .. escaped .. '"'
end

return M

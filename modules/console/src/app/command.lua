-- MIT. The native executor parses quoting without shell expansion/evaluation.
local M = {}
function M.encode(arguments: {string}): string
    if #arguments == 0 then return "/bin/bash -i" end
    local words: {string} = {}
    for _, argument in ipairs(arguments) do
        words[#words + 1] = "'" .. argument:gsub("'", "'\\''") .. "'"
    end
    return table.concat(words, " ")
end
return M

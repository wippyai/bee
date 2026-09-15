-- MIT. POSIX shell quoting for argv rendered as a line. The runtime executor
-- takes one command line and splits it with shell-like quoting, so placement
-- renders argv through this and nothing else; the same line serves display
-- and fixtures.
local M = {}
function M.posix(argument: string): string
    if #argument > 0 and not argument:find("[^%w%._/:=@%-]") then return argument end
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end
function M.line(argv: {string}): string
    local parts: {string} = {}
    for index, argument in ipairs(argv) do parts[index] = M.posix(argument) end
    return table.concat(parts, " ")
end
return M

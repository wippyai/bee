-- MIT. Native `bee gov revert` entry; it has no desktop or application caller.
local io = require("io")
local recovery = require("recovery")

local function main(operation: string?, owner: string?, ...)
    if operation ~= "revert" or not owner or select("#", ...) ~= 0 then
        error("usage: bee gov revert OWNER")
    end
    local message, failure = recovery.revert(owner)
    if not message then error(tostring(failure or "governance revert failed")) end
    assert(io.print(message))
end

return {main = main}

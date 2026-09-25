-- MIT. Command entry kept separate so it receives only the public display API.
local display = require("display")
local arguments = require("arguments")

local function command(...)
    local values = arguments.decode({...})
    if not values or #values ~= 4 then error("Usage: bee-display NODE OWNER_EXECUTION WORKSPACE DESKTOP") end
    return display.command(values[1], values[2], values[3], values[4])
end

return {command = command}

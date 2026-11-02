-- MIT. Reads one driver's tool.before reason as a hook endpoint scope does.
local capabilities = require("capabilities")
local function handle(driver: string): string
    return assert(capabilities.at(driver, "tool.before")).reason
end
return {handle = handle}

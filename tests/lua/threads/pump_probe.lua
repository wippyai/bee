-- MIT. Reports what the Threads pump configuration answers.
local pump_config = require("pump_config")

local function run(): {enabled: boolean?, error: string?}
    local enabled, enabled_error = pump_config.enabled()
    return {enabled = enabled, error = enabled_error}
end

return {run = run}

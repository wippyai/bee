-- MIT. Reports what the driver resolver answers for the pinned registry.
local registry = require("registry")
local resolver = require("resolver")

local function run(): {active: boolean, error: string?}
    local pinned, pin_error = registry.snapshot()
    if not pinned then return {active = false, error = tostring(pin_error)} end
    local active, active_error = resolver.active(pinned)
    return {active = active ~= nil, error = active_error}
end

return {run = run}

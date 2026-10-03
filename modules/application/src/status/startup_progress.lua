-- MIT. Retained startup progress values.
local M = {}

local STARTUP_PHASES: {[string]: boolean} = {
    booting = true, host_leasing = true, host_attaching = true,
    client_boot = true, admitting = true, rendering = true, running = true}
function M.decode(value: unknown): string?
    if type(value) ~= "table" or value.version ~= 1 or type(value.phase) ~= "string"
        or not STARTUP_PHASES[value.phase] then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "phase" then return nil end
    end
    return value.phase
end

return M

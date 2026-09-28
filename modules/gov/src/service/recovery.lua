-- MIT. One-shot boot gate: restore authorized destination intents before a
-- workspace host can build its first application catalog.
local service = require("service")

local function main()
    local recovered, recovery_error = service.recover_all()
    if not recovered then error("recover destination applications: " .. tostring(recovery_error)) end
end

return {main = main}

-- MIT. One-shot boot gate: restore authorized destination intents before a
-- workspace host can build its first application catalog. A restoration
-- governance refuses leaves that overlay out and is reported; the node boots.
local logger = require("logger")
local service = require("service")

local function main()
    local recovered, recovery_error, refused = service.recover_all()
    if not recovered then error("recover destination applications: " .. tostring(recovery_error)) end
    for _, reason in ipairs(refused or {}) do
        logger:warn("Overlay not restored; its activation needs review again", {reason = reason})
    end
end

return {main = main}

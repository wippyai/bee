-- MIT. A node restart for the delivery suites: registry overlays are
-- process-local, so a restarted node holds none of the named owners' entries
-- until boot recovery, run here under the recovery service's own policy,
-- restores them.
local registry = require("registry")
local service = require("service")

type Request = {owners: {string}}

local function restart(request: Request): {string}
    for _, owner in ipairs(request.owners) do
        local overlay = assert(registry.overlay(owner))
        local entries = assert(overlay:entries())
        if #entries > 0 then
            local changes = assert(overlay:changes())
            for _, entry in ipairs(entries) do assert(changes:delete(entry.id)) end
            assert(changes:apply())
        end
    end
    local recovered, recovery_error, refused = service.recover_all()
    if not recovered then error("recover destination applications: " .. tostring(recovery_error)) end
    return refused or {}
end

return {restart = restart}

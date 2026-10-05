-- MIT. Bounded approved installation effects for the host-authorized effect worker.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.installation_effects(request)
end
return {handle = handle}

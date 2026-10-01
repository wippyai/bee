-- MIT. Bounded approved publication effects for the host-authorized effect worker.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.publication_effects(request)
end
return {handle = handle}

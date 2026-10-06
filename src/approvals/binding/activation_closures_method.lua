-- MIT. Bounded governance activations whose request ended without approval, for the host-authorized activation worker.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.activation_closures(request)
end
return {handle = handle}

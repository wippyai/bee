-- MIT. Bounded approved governance activations for the host-authorized activation worker.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.activation_effects(request)
end
return {handle = handle}

-- MIT. The requester closes its activation whose request ended without approval.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.close_activation(request)
end
return {handle = handle}

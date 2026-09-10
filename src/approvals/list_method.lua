-- MIT. Approval owner method list, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.list(request)
end
return {handle = handle}

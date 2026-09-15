-- MIT. Approval owner method revalidate, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.revalidate(request)
end
return {handle = handle}

-- MIT. Approval owner method request, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.request(request)
end
return {handle = handle}

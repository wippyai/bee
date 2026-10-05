-- MIT. Approval owner method read, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.read(request)
end
return {handle = handle}

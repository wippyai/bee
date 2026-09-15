-- MIT. Approval owner method withdraw, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.withdraw(request)
end
return {handle = handle}

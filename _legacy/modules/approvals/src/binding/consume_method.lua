-- MIT. Approval owner method consume, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.consume(request)
end
return {handle = handle}

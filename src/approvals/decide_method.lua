-- MIT. Approval owner method decide, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.decide(request)
end
return {handle = handle}

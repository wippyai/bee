-- MIT. Approval owner method decide_batch, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.decide_batch(request)
end
return {handle = handle}

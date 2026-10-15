local service = require("service")
local function handle(request: unknown): service.Reply
    return service.consumed_decision(request)
end
return {handle = handle}

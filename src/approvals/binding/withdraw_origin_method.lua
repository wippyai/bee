local service = require("service")
local function handle(request: unknown): service.Reply
    return service.withdraw_origin(request)
end
return {handle = handle}

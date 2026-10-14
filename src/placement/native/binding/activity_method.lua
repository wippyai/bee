-- MIT. Placement method activity: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.activity(request)
end
return {handle = handle}

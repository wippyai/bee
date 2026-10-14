-- MIT. Placement method status: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.status(request)
end
return {handle = handle}

-- MIT. Placement method stop: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.stop(request)
end
return {handle = handle}

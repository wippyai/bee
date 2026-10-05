-- MIT. Placement method cleanup: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.cleanup(request)
end
return {handle = handle}

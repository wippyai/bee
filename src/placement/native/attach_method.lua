-- MIT. Placement method attach: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.attach(request)
end
return {handle = handle}

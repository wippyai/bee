-- MIT. Placement method forget_session: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.forget_session(request)
end
return {handle = handle}

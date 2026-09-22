-- MIT. Approval owner method reconcile, for the caller's actor.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.reconcile(request)
end
return {handle = handle}

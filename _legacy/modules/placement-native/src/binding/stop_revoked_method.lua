-- MIT. Host-authorized resource revocation stop: verify the recorded grant before stopping.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.stop_revoked(request)
end
return {handle = handle}

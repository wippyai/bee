-- MIT. Authenticated access to the approval owner's windows.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.grant_window(request)
end
return {handle = handle}

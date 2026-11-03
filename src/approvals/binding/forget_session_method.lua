-- MIT. Approval owner method forget_session: a removed session's requests end.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.forget_session(request)
end
return {handle = handle}

-- MIT. Placement method close_stdin: the caller's actor, the linked store, one operation.
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.close_stdin(request)
end
return {handle = handle}

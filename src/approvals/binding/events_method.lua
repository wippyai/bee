local service = require("service")
local M = {}
function M.handle(request: unknown): service.Reply
    return service.events(request)
end
return M

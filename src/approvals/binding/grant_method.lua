local service = require("service")
local M = {}
function M.handle(request: unknown): service.Reply
    return service.grant(request)
end
return M

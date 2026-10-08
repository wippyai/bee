local service = require("service")
local M = {}
function M.handle(request: unknown): service.Reply
    return service.effect(request)
end
return M

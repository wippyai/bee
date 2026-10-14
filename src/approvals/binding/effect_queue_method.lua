local service = require("service")
local M = {}
function M.handle(request: unknown): service.Reply
    return service.effect_queue(request)
end
return M

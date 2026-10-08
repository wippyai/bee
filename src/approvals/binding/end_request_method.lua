local service = require("service")
local M = {}
function M.handle(request: unknown): service.Reply
    return service.end_request(request)
end
return M

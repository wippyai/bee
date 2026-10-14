local dispatch = require("dispatch")
local service = require("service")
local M = {}
function M.run(): {ok: boolean, error: string?}
    local db = assert(service.open())
    local err = dispatch.notify_sessions(db)
    db:release()
    return {ok = err == nil, error = err}
end
return M

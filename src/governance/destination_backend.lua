-- MIT. Private destination backend. It runs only inside the destination
-- execution scope the public facade enters after it authenticates the caller's
-- exact delivery operation; the caller's own actor remains the recorded one.
local security = require("security")
local service = require("service")
local transaction = require("transaction")
local M = {}
function M.call(raw: unknown): transaction.Result
    if not security.can(service.EXECUTE, service.BACKEND) then
        return transaction.failure("DENIED", "destination backend is not authorized")
    end
    return service.call(raw)
end
return M

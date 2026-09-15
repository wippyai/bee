-- MIT. The public adapter retains the authenticated caller.
local service = require("service")
local function handle(request: unknown): service.Result
    return service.update_metadata(request)
end
return {handle = handle}

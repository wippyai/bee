-- MIT. Public profile facade; authorization and storage remain in service.
local service = require("service")
local function handle(request: unknown): service.Result
    return service.call(request)
end
return {handle = handle}

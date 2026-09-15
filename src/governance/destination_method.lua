-- MIT. Public destination review and activation facade.
local service = require("service")
local function handle(request: unknown)
    return service.call(request)
end
return {handle = handle}

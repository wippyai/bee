-- MIT. Public local publication facade.
local service = require("service")
local function handle(request: unknown)
    return service.call(request)
end
return {handle = handle}

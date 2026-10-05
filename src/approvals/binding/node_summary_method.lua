-- MIT.
local service = require("service")
local function handle(request: unknown): service.Reply return service.node_summary(request) end
return {handle = handle}

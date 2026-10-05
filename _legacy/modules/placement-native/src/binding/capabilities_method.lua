-- MIT. Placement method capabilities: what this runtime measures about itself.
local service = require("service")
local function handle(_: unknown): service.Reply
    return service.capabilities()
end
return {handle = handle}

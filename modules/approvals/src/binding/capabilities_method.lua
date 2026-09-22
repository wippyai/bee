-- MIT. Approval owner capabilities, for any caller.
local service = require("service")
local function handle(): service.Reply
    return service.capabilities()
end
return {handle = handle}

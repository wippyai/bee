-- MIT. Resource authority capabilities, for any caller.
local authority = require("authority")
local function handle(): authority.Reply
    return authority.capabilities()
end
return {handle = handle}

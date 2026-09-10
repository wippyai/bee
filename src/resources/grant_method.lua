-- MIT. Resource authority method grant: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.grant(request)
end
return {handle = handle}

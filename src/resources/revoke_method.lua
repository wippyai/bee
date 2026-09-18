-- MIT. Resource authority method revoke: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.revoke(request)
end
return {handle = handle}

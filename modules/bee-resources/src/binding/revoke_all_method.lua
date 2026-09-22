-- MIT. Resource authority method revoke_all: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.revoke_all(request)
end
return {handle = handle}

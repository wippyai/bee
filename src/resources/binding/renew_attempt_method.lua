-- MIT. Resource authority method renew_attempt: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.renew_attempt(request)
end
return {handle = handle}

-- MIT. Resource authority method list: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.list(request)
end
return {handle = handle}

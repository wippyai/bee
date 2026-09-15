-- MIT. Resource authority method resolve: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.resolve(request)
end
return {handle = handle}

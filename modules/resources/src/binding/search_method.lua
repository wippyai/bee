-- MIT. Resource authority method search: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.search(request)
end
return {handle = handle}

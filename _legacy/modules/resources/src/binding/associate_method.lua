-- MIT. Resource authority method associate: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.associate(request)
end
return {handle = handle}

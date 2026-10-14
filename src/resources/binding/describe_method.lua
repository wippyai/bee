-- MIT. Resource authority method describe: the caller's actor, the linked store, one operation.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.describe(request)
end
return {handle = handle}

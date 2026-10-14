-- MIT. Resource authority method check_grant: validate a thread-bound resource grant without writing it.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.check_grant(request)
end
return {handle = handle}

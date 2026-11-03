-- MIT. Resource authority method forget_session: a removed session's grants go.
local authority = require("authority")
local function handle(request: unknown): authority.Reply
    return authority.forget_session(request)
end
return {handle = handle}

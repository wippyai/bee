local boundary = require("boundary")
local authority = require("authority")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(authority.search, request)
end
return {handle = handle}

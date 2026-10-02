-- MIT. Authority method close: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local authority = require("authority")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(authority.close, request, true)
end
return {handle = handle}

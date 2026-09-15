-- MIT. Authority method get: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local authority = require("authority")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(authority.get, request)
end
return {handle = handle}

-- MIT. Authority method leave: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local authority = require("authority")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(authority.leave, request, true)
end
return {handle = handle}

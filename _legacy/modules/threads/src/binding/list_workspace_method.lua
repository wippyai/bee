-- MIT. Authority method list_workspace: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local authority = require("authority")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(authority.list_workspace, request)
end
return {handle = handle}

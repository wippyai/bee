-- MIT. Projection method status_read: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local status = require("status")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(status.read, request)
end
return {handle = handle}

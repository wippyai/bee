-- MIT. Projection method status_update: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local status = require("status")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(status.update, request, true)
end
return {handle = handle}

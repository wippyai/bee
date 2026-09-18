-- MIT. Projection method status_rebuild: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local status = require("status")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(status.rebuild, request, true)
end
return {handle = handle}

-- MIT. Lifecycle method admit_action: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local lifecycle = require("lifecycle")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(lifecycle.admit_action, request, true)
end
return {handle = handle}

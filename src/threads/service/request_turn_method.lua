-- MIT. Lifecycle method request_turn: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local lifecycle = require("lifecycle")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(lifecycle.request_turn, request, true)
end
return {handle = handle}
